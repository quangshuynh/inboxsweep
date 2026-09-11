import Foundation
import Security

/// The Gmail implementation of the app's provider boundary.
///
/// An actor, because it owns mutable authorization state that a bounded-concurrency fetch
/// touches from several tasks at once. Access tokens live here and are never handed out: the
/// only thing above this boundary can ask for is domain models.
actor GmailProvider: MailProvider {

    nonisolated let displayName = "Gmail"

    private let configuration: GmailOAuthConfiguration?
    private let transport: HTTPTransport
    private let webAuthenticator: WebAuthenticating
    private let credentialStore: GmailCredentialStoring
    private let retryPolicy: GmailAPIClient.RetryPolicy
    private let concurrency: Int

    private var storedCredentials: GmailStoredCredentials?
    private var accessToken: GmailAccessToken?
    private var connection: MailConnection = .disconnected
    private var refreshTask: Task<GmailAccessToken, Error>?

    /// Whether the current authorization made it into the credential store.
    ///
    /// Tracked rather than assumed. A write that fails is not worth failing a sign-in over, but
    /// it decides whether the next launch can restore anything at all, so it is not something
    /// to find out by discovering the app is signed out again.
    private var persistenceState: StoredAuthorizationState = .unknown

    init(
        configuration: GmailOAuthConfiguration?,
        transport: HTTPTransport = URLSessionHTTPTransport(),
        webAuthenticator: WebAuthenticating = WebAuthenticationSessionPresenter(),
        credentialStore: GmailCredentialStoring = KeychainCredentialStore(),
        retryPolicy: GmailAPIClient.RetryPolicy = .init(),
        concurrency: Int = GmailMessageFetcher.defaultConcurrency
    ) {
        self.configuration = configuration
        self.transport = transport
        self.webAuthenticator = webAuthenticator
        self.credentialStore = credentialStore
        self.retryPolicy = retryPolicy
        self.concurrency = concurrency
    }

    // MARK: - MailAccountAuthorizing

    func currentConnection() async -> MailConnection { connection }

    func restoreConnection() async -> MailRestoreOutcome {
        guard configuration != nil else { return .noStoredCredentials }

        let stored: GmailStoredCredentials?
        do {
            stored = try credentialStore.load()
        } catch let error as CredentialStoreError {
            // The distinction this interval exists to draw: the Keychain answering "no" is
            // not the same as the Keychain having nothing, and only one of them is a normal
            // first launch.
            if case .malformedStoredData = error { return .unusable(.storedCredentialsMalformed) }
            return .unusable(.credentialStoreUnreadable(reason: error.diagnosticDescription))
        } catch {
            return .unusable(.credentialStoreUnreadable(reason: "The saved sign-in on this Mac couldn't be read."))
        }

        guard let stored else { return .noStoredCredentials }

        // If the scopes the app needs have changed since the grant was stored, the stored
        // grant is not the one we want. Discard it and ask the user to connect again.
        guard stored.coversRequestedScopes else {
            if let failure = clearStoredCredentials() {
                // The grant is unusable *and* the store will not let go of it. The second half
                // is the one worth saying out loud: a Keychain that refuses to delete this
                // app's own item will refuse to write the replacement too, and the user would
                // otherwise meet that as a reconnect that silently fails to stick.
                return .unusable(.credentialStoreUnreadable(reason: failure.diagnosticDescription))
            }
            return .unusable(.scopesNoLongerSufficient)
        }

        storedCredentials = stored

        do {
            _ = try await currentAccessToken()
            let account = try await loadAccount()
            connection = .connected(account)
            persistenceState = .persisted
            return .restored(account)
        } catch {
            let providerError = MailProviderError.wrapping(error)
            guard providerError.requiresReauthentication else {
                // The grant may well be fine; the network or Gmail is not. Keep it.
                return .unusable(.providerUnavailable(providerError))
            }
            forgetCredentials()
            return .unusable(.authorizationRevoked)
        }
    }

    func storedAuthorizationState() async -> StoredAuthorizationState { persistenceState }

    func connect() async throws -> MailAccount {
        let oauth = try makeOAuthClient()

        do {
            let grant = try await oauth.authorize()

            // Google can grant less than was asked for. Detect that here rather than letting
            // it surface later as a confusing permission error mid-load.
            let granted = Set(grant.accessToken.grantedScopes)
            guard GmailScope.requested.allSatisfy(granted.contains) else {
                throw MailProviderError.insufficientPermissions(
                    reason: "InboxSweep needs read-only access to Gmail metadata to group your mail by sender."
                )
            }

            accessToken = grant.accessToken
            let account = try await loadAccount()

            if let refreshToken = grant.refreshToken {
                let credentials = GmailStoredCredentials(
                    refreshToken: refreshToken,
                    grantedScopes: grant.accessToken.grantedScopes,
                    accountEmailAddress: account.emailAddress.address
                )
                storedCredentials = credentials
                persistenceState = persist(credentials)
            } else {
                // Google omits the refresh token when the account has already granted this
                // client and the grant was not re-prompted. The session works; the next
                // launch will have nothing to restore from.
                persistenceState = .notPersisted(
                    reason: "Google didn't issue a new refresh token for this sign-in, so it can't be saved for next launch."
                )
            }

            connection = .connected(account)
            return account
        } catch {
            accessToken = nil
            connection = .disconnected
            persistenceState = .unknown
            throw MailProviderError.wrapping(error)
        }
    }

    func disconnect() async -> MailDisconnectOutcome {
        // Revoking tells Google to drop the grant, so signing out actually gives the access
        // back rather than just forgetting the token locally. There is nothing to revoke when
        // no token was ever obtained, and that is not a failure.
        var revoked = true
        if let token = accessToken {
            do {
                try await makeOAuthClient().revoke(token: token.value)
            } catch {
                revoked = false
            }
        }

        let removalFailure = forgetCredentials()

        // Ranked, because one notice is shown and a credential still on this Mac is the worse
        // of the two.
        if let removalFailure {
            return .storedCredentialRetained(reason: removalFailure.diagnosticDescription)
        }
        return revoked ? .complete : .grantNotRevoked
    }

    // MARK: - MailMessageFetching

    func fetchMessages(_ request: MailFetchRequest) async throws -> MailMessagePage {
        guard connection.isConnected else { throw MailProviderError.authorizationExpired }

        do {
            return try await GmailMessageFetcher(client: makeAPIClient(), concurrency: concurrency)
                .fetchMessages(request)
        } catch {
            let providerError = MailProviderError.wrapping(error)
            if providerError.requiresReauthentication { forgetCredentials() }
            throw providerError
        }
    }

    // MARK: - Internals

    private func loadAccount() async throws -> MailAccount {
        let profile = try await makeAPIClient().profile()
        return MailAccount(
            emailAddress: EmailAddressParser.parse(profile.emailAddress),
            providerDisplayName: displayName,
            providerMessageCount: profile.messagesTotal
        )
    }

    private func makeOAuthClient() throws -> GmailOAuthClient {
        guard let configuration else {
            throw MailProviderError.notConfigured(reason: GmailOAuthConfiguration.missingConfigurationReason)
        }
        return GmailOAuthClient(
            configuration: configuration,
            transport: transport,
            webAuthenticator: webAuthenticator
        )
    }

    private func makeAPIClient() -> GmailAPIClient {
        GmailAPIClient(
            transport: transport,
            accessToken: { [weak self] in
                guard let self else { throw MailProviderError.cancelled }
                return try await self.currentAccessToken()
            },
            retryPolicy: retryPolicy
        )
    }

    /// Returns a usable access token, refreshing at most once even when several concurrent
    /// metadata requests all notice the expiry at the same moment.
    private func currentAccessToken() async throws -> GmailAccessToken {
        if let accessToken, !accessToken.isExpired() { return accessToken }

        if let refreshTask { return try await refreshTask.value }

        guard let refreshToken = storedCredentials?.refreshToken else {
            throw MailProviderError.authorizationExpired
        }

        let oauth = try makeOAuthClient()
        let task = Task { try await oauth.refresh(using: refreshToken) }
        refreshTask = task

        do {
            let token = try await task.value
            refreshTask = nil
            accessToken = token
            return token
        } catch {
            refreshTask = nil
            throw MailProviderError.wrapping(error)
        }
    }

    /// Writes credentials and reports, in the user's terms, whether it worked.
    ///
    /// Never throws. Failing to persist costs the user a reconnect next launch; failing the
    /// sign-in they just completed would cost them the session as well, for no gain.
    private func persist(_ credentials: GmailStoredCredentials) -> StoredAuthorizationState {
        do {
            try credentialStore.save(credentials)
            return .persisted
        } catch let error as CredentialStoreError {
            return .notPersisted(
                reason: "InboxSweep couldn't save this sign-in to the Keychain, so you'll need to connect again next launch. \(error.diagnosticDescription)"
            )
        } catch {
            return .notPersisted(
                reason: "InboxSweep couldn't save this sign-in to the Keychain, so you'll need to connect again next launch."
            )
        }
    }

    /// Drops every trace of the current authorization and reports whether the *stored* copy
    /// really went with it.
    ///
    /// The in-memory half always succeeds. The Keychain half can refuse, and the result is a
    /// refresh token that outlives the sign-out it was supposed to end — so the failure is
    /// returned rather than discarded. Callers that have somewhere to put it (``disconnect()``)
    /// say so; callers reacting to a revoked grant already have a more specific thing to
    /// report, and the stale item they leave behind is one the provider has already rejected.
    @discardableResult
    private func forgetCredentials() -> CredentialStoreError? {
        refreshTask?.cancel()
        refreshTask = nil
        accessToken = nil
        storedCredentials = nil
        connection = .disconnected
        persistenceState = .unknown
        return clearStoredCredentials()
    }

    /// Deletes the stored credential, returning the error when the store refused.
    private func clearStoredCredentials() -> CredentialStoreError? {
        do {
            try credentialStore.clear()
            return nil
        } catch let error as CredentialStoreError {
            return error
        } catch {
            return .unhandled(KeychainStatus(errSecInternalError))
        }
    }
}

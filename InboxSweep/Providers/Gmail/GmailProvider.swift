import Foundation
import Security

/// The Gmail implementation of the app's provider boundary.
///
/// An actor, because it owns mutable authorization state that a bounded-concurrency fetch
/// touches from several tasks at once. Access tokens live here and are never handed out: the
/// only thing above this boundary can ask for is domain models.
actor GmailProvider: MailProvider, MailMessageArchiving {

    nonisolated let displayName = "Gmail"

    /// This provider *is* its own mutation boundary.
    ///
    /// Returning `self` rather than a separately-constructed helper is deliberate: the object
    /// that performs an archive is then, unavoidably, the object holding the authorization the
    /// messages were read with. There is no second instance whose idea of the connected account
    /// could drift from this one's.
    nonisolated var messageArchiver: (any MailMessageArchiving)? { self }

    /// The unsubscribe boundary, which is emphatically **not** `self`.
    ///
    /// The opposite decision from ``messageArchiver``, for the opposite reason. An archive has
    /// to be performed by the object holding the Gmail authorization, because it *is* a Gmail
    /// request. A one-click unsubscribe must not be: it goes to a host a stranger named in a
    /// mail header, and the object that sends it has no business being the one holding a Google
    /// access token.
    ///
    /// So it is a separate type, over a separate transport, that has never been given a token
    /// and has no parameter to receive one. "The Google token cannot reach an unsubscribe host"
    /// is then a property of the object graph rather than of a guard somebody has to remember.
    nonisolated var unsubscriber: (any MailUnsubscribing)? { unsubscribeClient }

    private let configuration: GmailOAuthConfiguration?
    private let transport: HTTPTransport
    private let webAuthenticator: WebAuthenticating
    private let credentialStore: GmailCredentialStoring
    private let retryPolicy: GmailAPIClient.RetryPolicy
    private let concurrency: Int

    /// The one-click client. Holds no credential of any kind and is never handed one.
    private let unsubscribeClient: any MailUnsubscribing

    private var storedCredentials: GmailStoredCredentials?
    private var accessToken: GmailAccessToken?
    private var connection: MailConnection = .disconnected
    private var refreshTask: Task<GmailAccessToken, Error>?

    /// What Google actually granted for the current authorization.
    ///
    /// Tracked rather than assumed equal to ``GmailScope/requested``, because Google can grant
    /// less than was asked for and because a grant stored by a version that predates the
    /// archive permission covers only reading. This set is what decides whether archiving is
    /// offered at all.
    ///
    /// Established at connect and restore and not updated on a token refresh: a refresh cannot
    /// widen a grant, and a grant that has *narrowed* shows up as Gmail refusing the request,
    /// which is reported honestly rather than pre-empted by guesswork.
    private var grantedScopes: Set<String> = []

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
        concurrency: Int = GmailMessageFetcher.defaultConcurrency,
        unsubscriber: any MailUnsubscribing = OneClickUnsubscribeClient()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.webAuthenticator = webAuthenticator
        self.credentialStore = credentialStore
        self.retryPolicy = retryPolicy
        self.concurrency = concurrency
        self.unsubscribeClient = unsubscriber
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

        // Only the *read* scopes decide whether a stored grant is usable. A grant written
        // before the archive permission existed reads a mailbox perfectly well, and discarding
        // it would sign out every existing user over a feature they have not asked to use, so
        // the missing archive scope is handled later, as a capability, not here as a fault.
        guard stored.coversReadScopes else {
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
        grantedScopes = Set(stored.grantedScopes)

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

            // Google can grant less than was asked for. Only the read scopes are worth
            // failing a sign-in over: without them there is no dashboard to show. A sign-in
            // that granted reading but not archiving is a working session with the archive
            // action unavailable, which ``archiveCapability()`` reports and the UI explains.
            let granted = Set(grant.accessToken.grantedScopes)
            guard GmailScope.coversReading(granted) else {
                throw MailProviderError.insufficientPermissions(
                    reason: "InboxSweep needs read-only access to Gmail metadata to group your mail by sender."
                )
            }

            grantedScopes = granted
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
            grantedScopes = []
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

    // MARK: - MailMessageArchiving

    func archiveCapability() async -> MailMutationCapability {
        // No configuration means no OAuth client, so there is nothing to upgrade *to*. Every
        // other "no" here is one more permission away from yes.
        guard configuration != nil else { return .unsupported }
        guard connection.isConnected, GmailScope.coversArchiving(grantedScopes) else {
            return .requiresAdditionalPermission
        }
        return .granted
    }

    func authorizeArchiving() async throws -> MailMutationCapability {
        guard let connectedAccount = connection.account else {
            throw MailMutationError.authorizationExpired
        }
        if GmailScope.coversArchiving(grantedScopes) { return .granted }

        let oauth: GmailOAuthClient
        do {
            oauth = try makeOAuthClient()
        } catch {
            throw MailMutationError.wrapping(error)
        }

        // Everything below can fail, and the session on screen is currently working. So the
        // existing token is put back on every failure path rather than left in whatever state
        // a half-finished re-authorization produced.
        let previousToken = accessToken

        do {
            let grant = try await oauth.authorize()
            let granted = Set(grant.accessToken.grantedScopes)

            guard GmailScope.coversArchiving(granted) else {
                // The user saw the consent screen and said no to the extra permission, or
                // Google granted less than was asked. Either way the read-only session they
                // already had is untouched.
                throw MailMutationError.permissionDeclined
            }

            accessToken = grant.accessToken
            let reauthorizedAccount = try await loadAccount()

            // Signing in again is an opportunity to land in a *different* mailbox: a second
            // Google account in the same browser session is all it takes. The window on screen
            // belongs to the first one, so the upgrade is refused rather than quietly switching
            // which mailbox the app is about to write to.
            guard reauthorizedAccount.emailAddress.address == connectedAccount.emailAddress.address else {
                accessToken = previousToken
                throw MailMutationError.accountChanged
            }

            grantedScopes = granted
            connection = .connected(reauthorizedAccount)
            persistUpgradedGrant(grant, for: reauthorizedAccount, granted: granted)
            return .granted
        } catch {
            accessToken = previousToken
            throw MailMutationError.wrapping(error)
        }
    }

    func archive(_ request: MailArchiveRequest) async throws -> MailArchiveReceipt {
        try await applyInboxChange(.archive, request)
    }

    func restoreToInbox(_ request: MailArchiveRequest) async throws -> MailArchiveReceipt {
        try await applyInboxChange(.restoreToInbox, request)
    }

    /// The single code path both mutations go through.
    ///
    /// One path rather than two because every check below applies to both, and a second copy is
    /// how an undo ends up with weaker account validation than the archive it reverses.
    private func applyInboxChange(
        _ operation: MailMutationOperation,
        _ request: MailArchiveRequest
    ) async throws -> MailArchiveReceipt {
        guard configuration != nil else { throw MailMutationError.notSupported }

        // Checked here as well as in the session, and not because the session is untrusted:
        // this is the boundary that actually holds the token, so this is where "acting for the
        // right account" has to be true. A caller cannot opt out of it.
        guard let connectedAccount = connection.account else {
            throw MailMutationError.authorizationExpired
        }
        guard connectedAccount.emailAddress.address == request.accountAddress else {
            throw MailMutationError.accountChanged
        }
        guard GmailScope.coversArchiving(grantedScopes) else {
            throw MailMutationError.permissionRequired
        }

        // The last moment cancellation is meaningful. Once the request is in flight Gmail may
        // already have applied it, and abandoning the task then would leave the app unsure
        // whether the mailbox changed, so cancellation is offered before the send and not
        // after, and the reconciliation below runs to completion either way.
        try Task.checkCancellation()

        let message: GmailDTO.Message
        do {
            message = try await makeAPIClient().modify(
                GmailMutationEndpoint.request(for: operation, messageID: request.messageID)
            )
        } catch {
            let mutationError = MailMutationError.wrapping(error)
            if mutationError == .authorizationExpired { forgetCredentials() }
            throw mutationError
        }

        // Gmail echoes the message back. Believing its labels rather than the ones the request
        // asked for is what keeps "InboxSweep thinks this is archived" and "this is archived"
        // the same sentence.
        let receipt = MailArchiveReceipt(
            messageID: MailMessageID(message.id),
            operation: operation,
            labelsAfterMutation: GmailMessageNormalizer.labels(from: message.labelIds ?? [])
        )

        guard receipt.messageID == request.messageID else {
            throw MailMutationError.rejectedByProvider(
                reason: "Gmail replied about a different message than the one InboxSweep asked about."
            )
        }
        guard receipt.confirmsOperation else {
            throw MailMutationError.rejectedByProvider(
                reason: "Gmail accepted the request but reported the message unchanged."
            )
        }

        return receipt
    }

    /// Writes the upgraded grant back, keeping the refresh token when Google issues no new one.
    ///
    /// Google omits the refresh token whenever the client already holds a live grant, which is
    /// precisely the situation an upgrade is. Treating that as "nothing to persist" would leave
    /// the stored credential claiming read-only scopes forever, and the next launch would offer
    /// the upgrade again to somebody who had already granted it.
    private func persistUpgradedGrant(
        _ grant: GmailOAuthClient.Grant,
        for account: MailAccount,
        granted: Set<String>
    ) {
        let scopes = Array(granted).sorted()

        if let refreshToken = grant.refreshToken {
            let credentials = GmailStoredCredentials(
                refreshToken: refreshToken,
                grantedScopes: scopes,
                accountEmailAddress: account.emailAddress.address
            )
            storedCredentials = credentials
            persistenceState = persist(credentials)
        } else if let existing = storedCredentials {
            let updated = existing.replacingGrantedScopes(scopes)
            storedCredentials = updated
            persistenceState = persist(updated)
        } else {
            persistenceState = .notPersisted(
                reason: "Google didn't issue a new refresh token for this sign-in, so the added permission can't be saved for next launch."
            )
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
    /// refresh token that outlives the sign-out it was supposed to end, so the failure is
    /// returned rather than discarded. Callers that have somewhere to put it (``disconnect()``)
    /// say so; callers reacting to a revoked grant already have a more specific thing to
    /// report, and the stale item they leave behind is one the provider has already rejected.
    @discardableResult
    private func forgetCredentials() -> CredentialStoreError? {
        refreshTask?.cancel()
        refreshTask = nil
        accessToken = nil
        grantedScopes = []
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

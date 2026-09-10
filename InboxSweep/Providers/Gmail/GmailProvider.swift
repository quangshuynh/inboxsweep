import Foundation

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

    func restoreConnection() async throws -> MailConnection {
        guard configuration != nil else { return .disconnected }

        // A failure to read the Keychain means "we have nothing", not "the app is broken".
        guard let stored = (try? credentialStore.load()) ?? nil else { return .disconnected }

        // If the scopes the app needs have changed since the grant was stored, the stored
        // grant is not the one we want. Discard it and ask the user to connect again.
        guard stored.coversRequestedScopes else {
            try? credentialStore.clear()
            return .disconnected
        }

        storedCredentials = stored

        do {
            _ = try await currentAccessToken()
            let account = try await loadAccount()
            connection = .connected(account)
            return connection
        } catch {
            let providerError = MailProviderError.wrapping(error)
            if providerError.requiresReauthentication { forgetCredentials() }
            throw providerError
        }
    }

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
                // Not being able to persist only costs the user a reconnect next launch, so
                // it must not fail a sign-in that has otherwise succeeded.
                try? credentialStore.save(credentials)
            }

            connection = .connected(account)
            return account
        } catch {
            accessToken = nil
            connection = .disconnected
            throw MailProviderError.wrapping(error)
        }
    }

    func disconnect() async {
        // Revoking tells Google to drop the grant, so signing out actually gives the access
        // back rather than just forgetting the token locally.
        if let token = accessToken, let oauth = try? makeOAuthClient() {
            try? await oauth.revoke(token: token.value)
        }
        forgetCredentials()
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

    private func forgetCredentials() {
        refreshTask?.cancel()
        refreshTask = nil
        accessToken = nil
        storedCredentials = nil
        connection = .disconnected
        try? credentialStore.clear()
    }
}

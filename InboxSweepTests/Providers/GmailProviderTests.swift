import Foundation
import Security
import Testing
@testable import InboxSweep

@Suite("Gmail provider")
struct GmailProviderTests {

    private let configuration = GmailOAuthConfiguration(
        clientID: "1234567890-abcdef.apps.googleusercontent.com"
    )!

    private func makeProvider(
        stub: GmailMailboxStub = GmailMailboxStub(),
        webAuthenticator: WebAuthenticating = FakeWebAuthenticator.granting(),
        store: GmailCredentialStoring = InMemoryCredentialStore(),
        configuration: GmailOAuthConfiguration? = nil
    ) -> (GmailProvider, RecordingHTTPTransport) {
        let transport = RecordingHTTPTransport(handler: stub.handler())
        let provider = GmailProvider(
            configuration: configuration ?? self.configuration,
            transport: transport,
            webAuthenticator: webAuthenticator,
            credentialStore: store,
            retryPolicy: .immediate,
            concurrency: 3
        )
        return (provider, transport)
    }

    // MARK: - Connecting

    @Test("Connecting reports the signed-in account and stores the refresh token")
    func connectsAndPersists() async throws {
        let store = InMemoryCredentialStore()
        let (provider, _) = makeProvider(store: store)

        let account = try await provider.connect()

        #expect(account.emailAddress.address == "sample.user@example.com")
        #expect(account.providerDisplayName == "Gmail")
        #expect(account.providerMessageCount == 4_210)
        #expect(await provider.currentConnection().isConnected)

        let stored = try #require(try store.load())
        #expect(stored.refreshToken == "refresh-token")
        #expect(stored.grantedScopes == [GmailScope.metadata])
    }

    @Test("A grant that covers less than the app needs is refused up front")
    func rejectsInsufficientGrant() async throws {
        var stub = GmailMailboxStub()
        stub.grantedScope = "https://www.googleapis.com/auth/userinfo.email"
        let store = InMemoryCredentialStore()
        let (provider, _) = makeProvider(stub: stub, store: store)

        let error = await #expect(throws: MailProviderError.self) { _ = try await provider.connect() }
        #expect(error?.requiresReauthentication == true)
        #expect(await provider.currentConnection() == .disconnected)
        // Nothing is stored from a grant the app cannot use.
        #expect(try store.load() == nil)
    }

    @Test("Cancelling sign-in leaves the provider disconnected, not half-connected")
    func cancelledSignInLeavesNoState() async throws {
        let (provider, _) = makeProvider(webAuthenticator: FakeWebAuthenticator.cancelling())

        await #expect(throws: MailProviderError.cancelled) { _ = try await provider.connect() }
        #expect(await provider.currentConnection() == .disconnected)
    }

    @Test("Without an OAuth client ID, connecting explains the setup instead of failing obscurely")
    func reportsMissingConfiguration() async throws {
        let transport = RecordingHTTPTransport(handler: GmailMailboxStub().handler())
        let provider = GmailProvider(
            configuration: nil,
            transport: transport,
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: InMemoryCredentialStore()
        )

        let error = await #expect(throws: MailProviderError.self) { _ = try await provider.connect() }
        guard case .notConfigured = try #require(error) else {
            Issue.record("Expected .notConfigured, got \(String(describing: error))")
            return
        }
        #expect(transport.requestCount == 0, "An unconfigured app must not contact Google at all")
    }

    // MARK: - Restoring

    @Test("A stored refresh token reconnects without any user interaction")
    func restoresStoredConnection() async throws {
        let store = InMemoryCredentialStore(credentials: GmailStoredCredentials(
            refreshToken: "refresh-token",
            grantedScopes: GmailScope.requested,
            accountEmailAddress: "sample.user@example.com"
        ))
        let (provider, _) = makeProvider(
            // A restore that opened a sign-in window would defeat the point.
            webAuthenticator: FakeWebAuthenticator { _, _ in
                Issue.record("Restoring must not present a sign-in window")
                throw MailProviderError.cancelled
            },
            store: store
        )

        let outcome = await provider.restoreConnection()
        #expect(outcome.account?.emailAddress.address == "sample.user@example.com")
    }

    @Test("With nothing stored, restoring lands on signed-out rather than erroring")
    func restoresNothingQuietly() async throws {
        let (provider, transport) = makeProvider()

        #expect(await provider.restoreConnection() == .noStoredCredentials)
        #expect(transport.requestCount == 0)
    }

    @Test("A credential store that refuses is reported as unreadable, never as an empty store")
    func distinguishesRefusalFromAbsence() async throws {
        // The defect this interval fixed, expressed as a test: a store that cannot answer must
        // not produce the same outcome as a store with nothing in it, because the app shows the
        // same signed-out screen for both and only one of them is normal.
        let (provider, _) = makeProvider(store: FailingCredentialStore(
            loadError: .accessDenied(KeychainStatus(errSecInteractionNotAllowed))
        ))

        let outcome = await provider.restoreConnection()

        guard case .unusable(.credentialStoreUnreadable(let reason)) = outcome else {
            Issue.record("Expected an unreadable credential store, got \(outcome)")
            return
        }
        #expect(reason.contains("errSecInteractionNotAllowed"))
        #expect(!reason.lowercased().contains("token"))
    }

    @Test("A stored blob that cannot be decoded is reported as malformed")
    func reportsMalformedStoredCredentials() async {
        let (provider, _) = makeProvider(store: FailingCredentialStore(loadError: .malformedStoredData))

        #expect(await provider.restoreConnection() == .unusable(.storedCredentialsMalformed))
    }

    @Test("A sign-in that could not be saved says so instead of failing quietly")
    func reportsCredentialsThatCouldNotBePersisted() async throws {
        // The original bug in one case: the Keychain rejected every write, sign-in carried on
        // looking perfect, and the next launch was signed out with nothing saying why.
        let store = FailingCredentialStore(
            saveError: .noUsableKeychain(KeychainStatus(errSecMissingEntitlement))
        )
        let (provider, _) = makeProvider(store: store)

        _ = try await provider.connect()
        let state = await provider.storedAuthorizationState()

        let warning = try #require(state.warning)
        #expect(warning.contains("errSecMissingEntitlement"))
        #expect(warning.contains("connect again next launch"))
        #expect(!warning.lowercased().contains("refresh-token"))
    }

    @Test("A sign-in that was saved reports itself as persisted")
    func reportsPersistedCredentials() async throws {
        let (provider, _) = makeProvider(store: InMemoryCredentialStore())

        _ = try await provider.connect()

        #expect(await provider.storedAuthorizationState() == .persisted)
    }

    @Test("A stored grant that predates the current scopes is discarded")
    func discardsStaleScopes() async throws {
        let store = InMemoryCredentialStore(credentials: GmailStoredCredentials(
            refreshToken: "refresh-token",
            grantedScopes: ["https://www.googleapis.com/auth/userinfo.email"],
            accountEmailAddress: "sample.user@example.com"
        ))
        let (provider, _) = makeProvider(store: store)

        #expect(await provider.restoreConnection() == .unusable(.scopesNoLongerSufficient))
        #expect(try store.load() == nil)
    }

    @Test("A revoked refresh token clears the stored credentials")
    func clearsRevokedCredentials() async throws {
        let store = InMemoryCredentialStore(credentials: GmailStoredCredentials(
            refreshToken: "revoked",
            grantedScopes: GmailScope.requested,
            accountEmailAddress: "sample.user@example.com"
        ))
        let transport = RecordingHTTPTransport { _, _ in
            HTTPResponse(statusCode: 400, body: Data(GmailFixtures.oauthErrorJSON("invalid_grant").utf8))
        }
        let provider = GmailProvider(
            configuration: configuration,
            transport: transport,
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: store,
            retryPolicy: .immediate
        )

        #expect(await provider.restoreConnection() == .unusable(.authorizationRevoked))
        #expect(try store.load() == nil)
    }

    // MARK: - Fetching

    @Test("A connected provider returns normalized domain models")
    func fetchesNormalizedMessages() async throws {
        let (provider, _) = makeProvider(stub: GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 6)))
        _ = try await provider.connect()

        let page = try await provider.fetchMessages(MailFetchRequest(limit: 6))

        #expect(page.messages.count == 6)
        #expect(page.messages.allSatisfy { $0.sender.hasAddress })
        #expect(Set(page.messages.map(\.sender.address)).count == 3)
    }

    @Test("Fetching before connecting is refused rather than attempted")
    func refusesFetchWhileDisconnected() async throws {
        let (provider, transport) = makeProvider()

        await #expect(throws: MailProviderError.authorizationExpired) {
            _ = try await provider.fetchMessages(MailFetchRequest())
        }
        #expect(transport.requestCount == 0)
    }

    // MARK: - Disconnecting

    @Test("Disconnecting revokes the grant, forgets the token, and returns to signed out")
    func disconnectsCompletely() async throws {
        let store = InMemoryCredentialStore()
        let (provider, transport) = makeProvider(store: store)
        _ = try await provider.connect()

        await provider.disconnect()

        #expect(await provider.currentConnection() == .disconnected)
        #expect(try store.load() == nil)
        #expect(transport.requests(matching: "revoke").count == 1)
    }

    @Test("Disconnecting succeeds even when revoking the grant fails")
    func disconnectsDespiteRevocationFailure() async throws {
        let store = InMemoryCredentialStore()
        let stubHandler = GmailMailboxStub().handler()
        let transport = RecordingHTTPTransport { request, attempt in
            if (request.url?.absoluteString ?? "").contains("revoke") {
                throw URLError(.notConnectedToInternet)
            }
            return try await stubHandler(request, attempt)
        }
        let provider = GmailProvider(
            configuration: configuration,
            transport: transport,
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: store,
            retryPolicy: .immediate
        )
        _ = try await provider.connect()

        await provider.disconnect()

        #expect(await provider.currentConnection() == .disconnected)
        #expect(try store.load() == nil)
    }
}

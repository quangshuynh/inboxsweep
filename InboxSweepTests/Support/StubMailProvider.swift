import Foundation
@testable import InboxSweep

/// A programmable provider for exercising ``InboxSessionModel`` without Gmail.
///
/// Deliberately implements the same boundary the real adapter does, so the session tests
/// describe behaviour the app would actually get from a provider rather than from a mock
/// shaped around the implementation.
actor StubMailProvider: MailProvider {

    nonisolated let displayName = "Stub"

    enum ConnectBehavior: Sendable {
        case succeeds(MailAccount)
        case fails(MailProviderError)
        /// Never returns on its own; used to test cancellation.
        case stalls
    }

    enum FetchBehavior: Sendable {
        /// Returned in order, one per call.
        case pages([MailMessagePage])
        case fails(MailProviderError)
        /// Never returns on its own; used to test cancellation.
        case stalls
    }

    private var connectBehavior: ConnectBehavior
    private var fetchBehavior: FetchBehavior
    private var connection: MailConnection = .disconnected

    private(set) var connectCallCount = 0
    private(set) var fetchCallCount = 0
    /// Every request the session made, so a test can assert *what* was asked for, notably
    /// the page cursor a relaunched session continues from.
    private(set) var fetchRequests: [MailFetchRequest] = []
    /// Indexes into the current `.pages` behaviour, so replacing the behaviour mid-test starts
    /// its pages from the beginning rather than continuing a previous run's count.
    private var pageCursor = 0
    private(set) var disconnectCallCount = 0
    private(set) var restoreCallCount = 0

    /// The outcome ``restoreConnection()`` reports.
    private var restoreOutcome: MailRestoreOutcome
    /// What ``storedAuthorizationState()`` reports after a connect or restore.
    private var authorizationState: StoredAuthorizationState

    /// The mutation boundary this provider vends, or `nil` for a provider that cannot write.
    ///
    /// `nonisolated let` so it is the same object for the life of the provider: the session
    /// reads it once at construction, exactly as it does with the real adapter.
    nonisolated let messageArchiver: (any MailMessageArchiving)?

    /// The unsubscribe boundary this provider vends, or `nil` for one that cannot send a
    /// one-click request.
    ///
    /// Independent of ``messageArchiver``, exactly as it is on the real adapter, so a test can
    /// describe a provider that can archive and not unsubscribe, or the reverse, and find out
    /// whether the session keeps the two apart.
    nonisolated let unsubscriber: (any MailUnsubscribing)?
    /// What ``disconnect()`` reports, so a test can drive the sign-out notices without needing
    /// a Keychain that refuses.
    private var disconnectOutcome: MailDisconnectOutcome = .complete

    init(
        connect: ConnectBehavior = .succeeds(.testAccount),
        fetch: FetchBehavior = .pages([.empty]),
        restorable: MailConnection = .disconnected,
        restoreOutcome: MailRestoreOutcome? = nil,
        authorizationState: StoredAuthorizationState = .unknown,
        archiver: (any MailMessageArchiving)? = nil,
        unsubscriber: (any MailUnsubscribing)? = nil
    ) {
        self.connectBehavior = connect
        self.fetchBehavior = fetch
        self.messageArchiver = archiver
        self.unsubscriber = unsubscriber
        self.restoreOutcome = restoreOutcome
            ?? restorable.account.map(MailRestoreOutcome.restored)
            ?? .noStoredCredentials
        self.authorizationState = authorizationState
    }

    func currentConnection() async -> MailConnection { connection }

    func restoreConnection() async -> MailRestoreOutcome {
        restoreCallCount += 1
        if let account = restoreOutcome.account { connection = .connected(account) }
        return restoreOutcome
    }

    func storedAuthorizationState() async -> StoredAuthorizationState { authorizationState }

    func connect() async throws -> MailAccount {
        connectCallCount += 1
        switch connectBehavior {
        case .succeeds(let account):
            connection = .connected(account)
            return account
        case .fails(let error):
            throw error
        case .stalls:
            try await Task.sleep(for: .seconds(60))
            throw MailProviderError.cancelled
        }
    }

    func disconnect() async -> MailDisconnectOutcome {
        disconnectCallCount += 1
        connection = .disconnected
        return disconnectOutcome
    }

    func fetchMessages(_ request: MailFetchRequest) async throws -> MailMessagePage {
        let pageIndex = pageCursor
        pageCursor += 1
        fetchCallCount += 1
        fetchRequests.append(request)

        switch fetchBehavior {
        case .pages(let pages):
            guard pageIndex < pages.count else { return .empty }
            return pages[pageIndex]
        case .fails(let error):
            throw error
        case .stalls:
            try await Task.sleep(for: .seconds(60))
            throw MailProviderError.cancelled
        }
    }

    /// Changes what a sign-out reports, so the notices for a retained credential and an
    /// unrevoked grant can be exercised.
    func setDisconnectOutcome(_ outcome: MailDisconnectOutcome) {
        disconnectOutcome = outcome
    }

    /// Replaces the connected account without a sign-in, so a test can reproduce the account
    /// changing between choosing a message and confirming it.
    func setConnection(_ connection: MailConnection) {
        self.connection = connection
    }

    /// Changes behaviour mid-test, e.g. to make a retry succeed after a failure.
    func setFetchBehavior(_ behavior: FetchBehavior) {
        fetchBehavior = behavior
        pageCursor = 0
    }
}

extension MailAccount {
    /// `nonisolated` because the project compiles with `MainActor` as the default isolation,
    /// which would otherwise make this constant main-actor-isolated and therefore unusable as a
    /// default argument in an actor's initializer.
    nonisolated static let testAccount = MailAccount(
        emailAddress: EmailAddressParser.parse("Sample User <sample.user@example.com>"),
        providerDisplayName: "Stub",
        providerMessageCount: 1_234
    )
}

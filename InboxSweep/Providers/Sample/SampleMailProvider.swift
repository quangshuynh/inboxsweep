#if DEBUG
import Foundation

/// An in-memory provider backed by entirely synthetic mail.
///
/// Exists so the dashboard can be developed, previewed, and demonstrated without a Google
/// account, and so nobody has to point the app at a real inbox to see whether a layout change
/// worked. Debug-only: it is not compiled into a release build.
///
/// Every address below is in an RFC 2606 reserved domain (`example.com`, `.org`, `.net`).
/// None of this data came from a real mailbox.
actor SampleMailProvider: MailProvider {

    nonisolated let displayName = "Sample data"

    /// The unsubscribe boundary, which is `nil` unless a debug launch argument asked for one.
    ///
    /// Default-off, matching how this provider treats archiving: an ordinary sample run has no
    /// boundary at all, so the confirmation is *absent* rather than disabled and a synthetic
    /// session cannot reach a write even by accident. Under
    /// ``SampleUnsubscribe/launchArgument`` it gets ``SampleUnsubscriber``, which answers
    /// in-process and has no transport to reach a network with.
    nonisolated var unsubscriber: (any MailUnsubscribing)? { sampleUnsubscriber }

    private let sampleUnsubscriber: (any MailUnsubscribing)?

    /// The archive boundary, `nil` unless a debug launch argument asked for one.
    ///
    /// Default-off, exactly like ``unsubscriber``. An ordinary sample run still has no way to
    /// archive at all, so the Archive control is absent rather than disabled and a synthetic
    /// session cannot reach a write even by accident. Under ``SampleRules/archivingLaunchArgument``
    /// it gets ``SampleArchiver``, which edits an in-memory label set and has no transport.
    nonisolated var messageArchiver: (any MailMessageArchiving)? { sampleArchiver }

    private let sampleArchiver: (any MailMessageArchiving)?

    private let messages: [MailMessage]
    private let pageSize: Int
    private let account: MailAccount
    private var connection: MailConnection = .disconnected

    init(
        messages: [MailMessage] = SampleMailbox.messages(),
        pageSize: Int = 60,
        account: MailAccount = SampleMailbox.account,
        unsubscriber: (any MailUnsubscribing)? = SampleUnsubscribe.unsubscriber(),
        archiver: (any MailMessageArchiving)? = SampleRules.archiver()
    ) {
        self.sampleUnsubscriber = unsubscriber
        self.sampleArchiver = archiver
        self.messages = messages
        self.pageSize = max(1, pageSize)
        self.account = MailAccount(
            emailAddress: account.emailAddress,
            providerDisplayName: account.providerDisplayName,
            providerMessageCount: messages.count
        )
    }

    /// A provider that starts already connected, for previews that show the dashboard.
    static func connected(messages: [MailMessage] = SampleMailbox.messages()) async -> SampleMailProvider {
        let provider = SampleMailProvider(messages: messages)
        _ = try? await provider.connect()
        return provider
    }

    func currentConnection() async -> MailConnection { connection }

    func restoreConnection() async -> MailRestoreOutcome {
        // Synthetic mail is never persisted, so there is never anything to restore.
        connection.account.map(MailRestoreOutcome.restored) ?? .noStoredCredentials
    }

    func storedAuthorizationState() async -> StoredAuthorizationState { .unknown }

    func connect() async throws -> MailAccount {
        connection = .connected(account)
        return account
    }

    func disconnect() async -> MailDisconnectOutcome {
        connection = .disconnected
        // Nothing was ever stored and nothing was ever granted, so there is nothing that
        // could have failed to be removed.
        return .complete
    }

    func fetchMessages(_ request: MailFetchRequest) async throws -> MailMessagePage {
        guard connection.isConnected else { throw MailProviderError.authorizationExpired }
        try Task.checkCancellation()

        let sorted = messages
            .filter { Self.matches(request.scope, $0) }
            .sorted { $0.receivedAt > $1.receivedAt }
        let offset = request.pageToken.flatMap { Int($0.rawValue) } ?? 0
        guard offset < sorted.count else { return .empty }

        let end = min(offset + min(request.limit, pageSize), sorted.count)
        return MailMessagePage(
            messages: Array(sorted[offset..<end]),
            nextPageToken: end < sorted.count ? MailPageToken(String(end)) : nil
        )
    }

    /// Mirrors what the Gmail adapter's `labelIds` filter does, so the scope picker behaves the
    /// same way against synthetic mail as against a real mailbox.
    private static func matches(_ scope: MailboxScope, _ message: MailMessage) -> Bool {
        switch scope {
        case .allMail: true
        case .inbox: message.labels.contains(.inbox)
        case .promotions: message.labels.contains(.categoryPromotions)
        case .updates: message.labels.contains(.categoryUpdates)
        case .social: message.labels.contains(.categorySocial)
        case .forums: message.labels.contains(.categoryForums)
        }
    }
}
#endif

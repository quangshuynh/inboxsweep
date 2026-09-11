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

    private let messages: [MailMessage]
    private let pageSize: Int
    private let account: MailAccount
    private var connection: MailConnection = .disconnected

    init(
        messages: [MailMessage] = SampleMailbox.messages(),
        pageSize: Int = 60,
        account: MailAccount = SampleMailbox.account
    ) {
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

    func restoreConnection() async throws -> MailConnection { connection }

    func connect() async throws -> MailAccount {
        connection = .connected(account)
        return account
    }

    func disconnect() async {
        connection = .disconnected
    }

    func fetchMessages(_ request: MailFetchRequest) async throws -> MailMessagePage {
        guard connection.isConnected else { throw MailProviderError.authorizationExpired }
        try Task.checkCancellation()

        let sorted = messages.sorted { $0.receivedAt > $1.receivedAt }
        let offset = request.pageToken.flatMap { Int($0.rawValue) } ?? 0
        guard offset < sorted.count else { return .empty }

        let end = min(offset + min(request.limit, pageSize), sorted.count)
        return MailMessagePage(
            messages: Array(sorted[offset..<end]),
            nextPageToken: end < sorted.count ? MailPageToken(String(end)) : nil
        )
    }
}
#endif

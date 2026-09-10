import Foundation

/// Fetches one bounded window of message metadata from Gmail.
///
/// Gmail's list endpoint returns IDs only, so a window costs one list request plus one
/// metadata request per message. Those metadata requests run concurrently, but through a
/// fixed-size window rather than a task per message: fanning out 250 simultaneous requests
/// would get the account throttled and would make cancellation slower, not faster.
nonisolated struct GmailMessageFetcher: Sendable {

    /// How many metadata requests are in flight at once.
    ///
    /// Chosen to keep the first screen fast while staying well inside Gmail's per-user rate
    /// limit; the API client's backoff handles the rest if the account is busy elsewhere.
    static let defaultConcurrency = 6

    private let client: GmailAPIClient
    private let concurrency: Int

    init(client: GmailAPIClient, concurrency: Int = defaultConcurrency) {
        self.client = client
        self.concurrency = max(1, concurrency)
    }

    func fetchMessages(_ request: MailFetchRequest) async throws -> MailMessagePage {
        let list = try await client.listMessages(
            limit: request.limit,
            pageToken: request.pageToken,
            scope: request.scope
        )

        let identifiers = Self.deduplicate((list.messages ?? []).map { MailMessageID($0.id) })
        let metadata = try await fetchMetadata(for: identifiers)

        return MailMessagePage(
            messages: GmailMessageNormalizer.normalize(metadata),
            nextPageToken: list.nextPageToken.flatMap { $0.isEmpty ? nil : MailPageToken($0) }
        )
    }

    /// Gmail can list the same ID twice across a page boundary; requesting it twice would
    /// double-count the sender as well as wasting quota.
    static func deduplicate(_ identifiers: [MailMessageID]) -> [MailMessageID] {
        var seen = Set<MailMessageID>()
        return identifiers.filter { seen.insert($0).inserted }
    }

    /// Fetches metadata for each ID, preserving the order Gmail listed them in.
    private func fetchMetadata(for identifiers: [MailMessageID]) async throws -> [GmailDTO.Message] {
        guard !identifiers.isEmpty else { return [] }

        var results = [GmailDTO.Message?](repeating: nil, count: identifiers.count)

        try await withThrowingTaskGroup(of: (Int, GmailDTO.Message?).self) { group in
            var nextIndex = 0

            func addTask(at index: Int) {
                group.addTask {
                    (index, try await self.metadataTolerating404(for: identifiers[index]))
                }
            }

            while nextIndex < min(concurrency, identifiers.count) {
                addTask(at: nextIndex)
                nextIndex += 1
            }

            while let (index, message) = try await group.next() {
                results[index] = message
                if nextIndex < identifiers.count {
                    addTask(at: nextIndex)
                    nextIndex += 1
                }
            }
        }

        return results.compactMap(\.self)
    }

    /// A message can be deleted by the user between listing and fetching. That is a normal
    /// race, not a failure of the load, so the message is skipped instead of failing the page.
    private func metadataTolerating404(for id: MailMessageID) async throws -> GmailDTO.Message? {
        do {
            return try await client.messageMetadata(id: id)
        } catch MailProviderError.providerFailure(statusCode: 404, _) {
            return nil
        }
    }
}

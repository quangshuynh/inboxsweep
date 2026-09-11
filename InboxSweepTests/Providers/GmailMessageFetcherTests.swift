import Foundation
import Testing
@testable import InboxSweep

@Suite("Gmail message fetching")
struct GmailMessageFetcherTests {

    private func fetcher(
        transport: HTTPTransport,
        concurrency: Int = GmailMessageFetcher.defaultConcurrency
    ) -> GmailMessageFetcher {
        GmailMessageFetcher(
            client: GmailAPIClient(
                transport: transport,
                accessToken: { GmailAccessToken(value: "t", expiresAt: .distantFuture, grantedScopes: GmailScope.requested) },
                retryPolicy: .immediate,
                sleep: { _ in }
            ),
            concurrency: concurrency
        )
    }

    @Test("A window is listed once, then fetched one message at a time")
    func listsThenFetchesMetadata() async throws {
        let transport = RecordingHTTPTransport(handler: GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 5)).handler())

        let page = try await fetcher(transport: transport).fetchMessages(MailFetchRequest(limit: 5))

        #expect(page.messages.count == 5)
        #expect(transport.requests(matching: "/messages?").count == 1)
        #expect(transport.requests(matching: "/messages/").count == 5)
    }

    @Test("Only metadata is ever requested, never a message body")
    func requestsMetadataOnly() async throws {
        let transport = RecordingHTTPTransport(handler: GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 3)).handler())
        _ = try await fetcher(transport: transport).fetchMessages(MailFetchRequest(limit: 3))

        for request in transport.requests(matching: "/messages/") {
            let url = try #require(request.url?.absoluteString)
            #expect(url.contains("format=metadata"))
            #expect(!url.contains("format=full"))
            #expect(!url.contains("format=raw"))
        }
    }

    @Test("Gmail's listed order is preserved even though fetches run concurrently")
    func preservesListOrder() async throws {
        let messages = GmailFixtures.mailbox(messageCount: 12)
        let transport = RecordingHTTPTransport(handler: GmailMailboxStub(messages: messages).handler())

        let page = try await fetcher(transport: transport, concurrency: 4)
            .fetchMessages(MailFetchRequest(limit: 12))

        #expect(page.messages.map(\.id.rawValue) == messages.map(\.id))
    }

    @Test("Concurrency stays inside the configured bound")
    func boundsConcurrency() async throws {
        let stub = GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 12))
        let handler = stub.handler()
        let transport = RecordingHTTPTransport { request, attempt in
            // Hold each metadata request open long enough that an unbounded implementation
            // would have all twelve in flight at once.
            if (request.url?.absoluteString ?? "").contains("/messages/") {
                try await Task.sleep(for: .milliseconds(15))
            }
            return try await handler(request, attempt)
        }

        _ = try await fetcher(transport: transport, concurrency: 3).fetchMessages(MailFetchRequest(limit: 12))

        #expect(transport.peakConcurrency <= 3)
    }

    @Test("A duplicated ID is fetched once, not twice")
    func deduplicatesIdentifiers() {
        let identifiers = ["a", "b", "a", "c", "b"].map { MailMessageID($0) }
        #expect(GmailMessageFetcher.deduplicate(identifiers).map(\.rawValue) == ["a", "b", "c"])
    }

    @Test("A message deleted between listing and fetching is skipped, not fatal")
    func toleratesMessagesThatVanish() async throws {
        var stub = GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 6))
        stub.missingMessageIDs = ["m002", "m004"]
        let transport = RecordingHTTPTransport(handler: stub.handler())

        let page = try await fetcher(transport: transport).fetchMessages(MailFetchRequest(limit: 6))

        #expect(page.messages.count == 4)
        #expect(!page.messages.map(\.id.rawValue).contains("m002"))
    }

    @Test("A page token is surfaced so the next window can be requested")
    func exposesPagination() async throws {
        let stub = GmailMailboxStub(pages: [
            GmailFixtures.mailbox(messageCount: 3),
            [GmailFixtures.SyntheticMessage(id: "p2-a"), GmailFixtures.SyntheticMessage(id: "p2-b")],
        ])
        let transport = RecordingHTTPTransport(handler: stub.handler())
        let fetcher = fetcher(transport: transport)

        let first = try await fetcher.fetchMessages(MailFetchRequest(limit: 3))
        let token = try #require(first.nextPageToken)
        #expect(first.hasMorePages)

        let second = try await fetcher.fetchMessages(MailFetchRequest(limit: 3).nextPage(after: token))
        #expect(second.messages.map(\.id.rawValue) == ["p2-a", "p2-b"])
        #expect(!second.hasMorePages)
    }

    @Test("An empty mailbox produces an empty page rather than an error")
    func handlesEmptyMailbox() async throws {
        let transport = RecordingHTTPTransport(handler: GmailMailboxStub(messages: []).handler())
        let page = try await fetcher(transport: transport).fetchMessages(MailFetchRequest())

        #expect(page.messages.isEmpty)
        #expect(!page.hasMorePages)
    }

    @Test("Cancelling a load stops it and reports cancellation")
    func honoursCancellation() async throws {
        let stub = GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 20))
        let handler = stub.handler()
        let transport = RecordingHTTPTransport { request, attempt in
            if (request.url?.absoluteString ?? "").contains("/messages/") {
                try await Task.sleep(for: .seconds(60))
            }
            return try await handler(request, attempt)
        }
        let fetcher = fetcher(transport: transport, concurrency: 2)

        let task = Task { try await fetcher.fetchMessages(MailFetchRequest(limit: 20)) }
        while transport.requests(matching: "/messages/").isEmpty { await Task.yield() }
        task.cancel()

        await #expect(throws: MailProviderError.cancelled) { try await task.value }
        // Cancellation stops the fan-out rather than letting the remaining window drain.
        #expect(transport.requests(matching: "/messages/").count < 20)
    }

    @Test("The listed scope selects the inbox label without using a search query")
    func listsWithinScope() async throws {
        let transport = RecordingHTTPTransport(handler: GmailMailboxStub(messages: []).handler())
        _ = try await fetcher(transport: transport).fetchMessages(MailFetchRequest(limit: 10, scope: .inbox))

        let url = try #require(transport.requests(matching: "/messages?").first?.url?.absoluteString)
        #expect(url.contains("labelIds=INBOX"))
        #expect(url.contains("maxResults=10"))
        // `q=` is unavailable under the gmail.metadata scope; asking for it would mean asking
        // for a wider permission than the app needs.
        #expect(!url.contains("q="))
    }
}

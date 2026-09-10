import Foundation
import Testing
@testable import InboxSweep

@MainActor
@Suite("Inbox session")
struct InboxSessionModelTests {

    // MARK: - Fixtures

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func message(_ id: String, from: String?, hours: Double, unread: Bool = false) -> MailMessage {
        MailMessage(
            id: MailMessageID(id),
            sender: EmailAddressParser.parse(from),
            subject: "Subject \(id)",
            receivedAt: Self.epoch.addingTimeInterval(hours * 3600),
            labels: unread ? [.inbox, .unread] : [.inbox]
        )
    }

    /// Two senders: `newsletter@example.com` with three messages, `person@example.net` with one.
    private func firstPage(nextPageToken: String? = nil) -> MailMessagePage {
        MailMessagePage(
            messages: [
                message("1", from: "Newsletter <newsletter@example.com>", hours: 4, unread: true),
                message("2", from: "newsletter@example.com", hours: 3),
                message("3", from: "NEWSLETTER@example.com", hours: 2, unread: true),
                message("4", from: "Jordan <person@example.net>", hours: 1),
            ],
            nextPageToken: nextPageToken.map(MailPageToken.init)
        )
    }

    private func secondPage() -> MailMessagePage {
        MailMessagePage(messages: [
            message("5", from: "alerts@example.org", hours: 8),
            message("6", from: "alerts@example.org", hours: 7),
            message("7", from: "alerts@example.org", hours: 6),
            message("8", from: "alerts@example.org", hours: 5),
        ])
    }

    /// Spins until `condition` holds, failing rather than hanging if it never does.
    private func wait(
        for description: String,
        until condition: @Sendable () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
    }

    // MARK: - Starting state

    @Test("A new session starts signed out")
    func startsSignedOut() {
        let model = InboxSessionModel(provider: StubMailProvider())
        #expect(model.state == .signedOut)
        #expect(model.account == nil)
        #expect(!model.state.isBusy)
    }

    // MARK: - Connecting

    @Test("Connecting loads a window and aggregates it by sender")
    func connectsAndLoads() async throws {
        let model = InboxSessionModel(provider: StubMailProvider(fetch: .pages([firstPage()])))

        await model.connect().value

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.account == .testAccount)
        #expect(snapshot.loadedMessageCount == 4)
        #expect(snapshot.senderCount == 2)
        #expect(snapshot.unreadMessageCount == 2)
        #expect(snapshot.senders.first?.sender.address == "newsletter@example.com")
        #expect(snapshot.senders.first?.messageCount == 3)
        #expect(!snapshot.hasMoreMessages)
    }

    @Test("A failed sign-in becomes an error the user can act on")
    func reportsAuthenticationFailure() async {
        let model = InboxSessionModel(
            provider: StubMailProvider(connect: .fails(.authenticationFailed(reason: "Google said no.")))
        )

        await model.connect().value

        #expect(model.state == .failed(.authenticationFailed(reason: "Google said no."), account: nil))
        #expect(model.account == nil)
    }

    @Test("Backing out of the sign-in window returns to the start, not to an error")
    func cancelledSignInReturnsToSignedOut() async {
        let provider = StubMailProvider(connect: .stalls)
        let model = InboxSessionModel(provider: provider)

        let task = model.connect()
        await wait(for: "sign-in to begin") { await provider.connectCallCount > 0 }
        model.cancel()
        await task.value

        #expect(model.state == .signedOut)
    }

    // MARK: - Loading

    @Test("A mailbox with no messages is an empty result, not a failure")
    func handlesEmptyMailbox() async throws {
        let model = InboxSessionModel(provider: StubMailProvider(fetch: .pages([.empty])))

        await model.connect().value

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.isEmpty)
        #expect(snapshot.senders.isEmpty)
    }

    @Test("A failed load keeps the account, so the user is offered a retry")
    func reportsLoadFailure() async {
        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .fails(.network(reason: "Offline.")))
        )

        await model.connect().value

        #expect(model.state == .failed(.network(reason: "Offline."), account: .testAccount))
        #expect(model.account == .testAccount)
    }

    @Test("A load that needs re-consent drops the account, so the user is offered a reconnect")
    func reportsExpiredAuthorization() async {
        let model = InboxSessionModel(provider: StubMailProvider(fetch: .fails(.authorizationExpired)))

        await model.connect().value

        #expect(model.state == .failed(.authorizationExpired, account: nil))
    }

    @Test("Cancelling a load reports cancellation rather than an alarming failure")
    func cancelsLoad() async {
        let provider = StubMailProvider(fetch: .stalls)
        let model = InboxSessionModel(provider: provider)

        let task = model.connect()
        await wait(for: "the load to begin") { await provider.fetchCallCount > 0 }
        model.cancel()
        await task.value

        #expect(model.state == .failed(.cancelled, account: .testAccount))
    }

    @Test("Retrying after a failure re-fetches and recovers")
    func retriesAfterFailure() async throws {
        let provider = StubMailProvider(fetch: .fails(.network(reason: "Offline.")))
        let model = InboxSessionModel(provider: provider)
        await model.connect().value
        #expect(model.state == .failed(.network(reason: "Offline."), account: .testAccount))

        await provider.setFetchBehavior(.pages([firstPage()]))
        await model.reload().value

        #expect(try #require(model.state.snapshot).loadedMessageCount == 4)
        #expect(await provider.connectCallCount == 1, "Retrying a load must not force a fresh sign-in")
    }

    // MARK: - Restoring

    @Test("A restorable connection loads straight into the dashboard")
    func restoresConnection() async throws {
        let model = InboxSessionModel(provider: StubMailProvider(
            fetch: .pages([firstPage()]),
            restorable: .connected(.testAccount)
        ))

        await model.restore().value

        #expect(try #require(model.state.snapshot).loadedMessageCount == 4)
    }

    @Test("Nothing stored means signed out, silently")
    func restoresNothing() async {
        let model = InboxSessionModel(provider: StubMailProvider(restorable: .disconnected))
        await model.restore().value
        #expect(model.state == .signedOut)
    }

    @Test("A stored authorization that no longer works sends the user to sign in, not to an error")
    func restoreFailureIsQuiet() async {
        let model = InboxSessionModel(provider: StubMailProvider(restoreError: .authorizationExpired))
        await model.restore().value
        #expect(model.state == .signedOut)
    }

    @Test("A restore failure that is not about permission is still shown")
    func restoreSurfacesRealFailures() async {
        let model = InboxSessionModel(provider: StubMailProvider(restoreError: .network(reason: "Offline.")))
        await model.restore().value
        #expect(model.state == .failed(.network(reason: "Offline."), account: nil))
    }

    // MARK: - Pagination

    @Test("Loading more merges the next page into the same aggregation")
    func loadsMorePages() async throws {
        let model = InboxSessionModel(provider: StubMailProvider(
            fetch: .pages([firstPage(nextPageToken: "page-2"), secondPage()])
        ))

        await model.connect().value
        #expect(try #require(model.state.snapshot).hasMoreMessages)

        await model.loadMore().value

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.loadedMessageCount == 8)
        #expect(snapshot.senderCount == 3)
        #expect(!snapshot.hasMoreMessages)
        #expect(!snapshot.isLoadingMore)
        // The new page has four messages from one sender, which now outranks the newsletter.
        #expect(snapshot.senders.first?.sender.address == "alerts@example.org")
    }

    @Test("A failed extra page leaves the already-loaded window intact")
    func failedPageKeepsExistingWindow() async throws {
        let provider = StubMailProvider(fetch: .pages([firstPage(nextPageToken: "page-2")]))
        let model = InboxSessionModel(provider: provider)
        await model.connect().value

        await provider.setFetchBehavior(.fails(.network(reason: "Offline.")))
        await model.loadMore().value

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.loadedMessageCount == 4)
        #expect(!snapshot.isLoadingMore)
    }

    @Test("Loading more is a no-op when there is no next page")
    func loadMoreWithoutPagesDoesNothing() async throws {
        let provider = StubMailProvider(fetch: .pages([firstPage()]))
        let model = InboxSessionModel(provider: provider)
        await model.connect().value

        await model.loadMore().value

        #expect(await provider.fetchCallCount == 1)
    }

    // MARK: - Sorting

    @Test("Changing the sort order re-sorts what is loaded without re-fetching")
    func resortsWithoutRefetching() async throws {
        let provider = StubMailProvider(fetch: .pages([firstPage()]))
        let model = InboxSessionModel(provider: provider)
        await model.connect().value
        #expect(model.state.snapshot?.senders.first?.sender.address == "newsletter@example.com")

        model.sortOrder = .senderName

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.sortOrder == .senderName)
        #expect(snapshot.senders.first?.sender.displayValue == "Jordan")
        #expect(await provider.fetchCallCount == 1, "Re-sorting must not cost a network round trip")
    }

    // MARK: - Signing out

    @Test("Disconnecting signs out of the provider and clears the loaded window")
    func disconnects() async throws {
        let provider = StubMailProvider(fetch: .pages([firstPage()]))
        let model = InboxSessionModel(provider: provider)
        await model.connect().value

        await model.disconnect().value

        #expect(model.state == .signedOut)
        #expect(model.account == nil)
        #expect(await provider.disconnectCallCount == 1)
    }

    @Test("Connecting again after signing out starts from a clean window")
    func reconnectsCleanly() async throws {
        let provider = StubMailProvider(fetch: .pages([firstPage(), firstPage()]))
        let model = InboxSessionModel(provider: provider)

        await model.connect().value
        await model.disconnect().value
        await model.connect().value

        #expect(try #require(model.state.snapshot).loadedMessageCount == 4)
    }
}

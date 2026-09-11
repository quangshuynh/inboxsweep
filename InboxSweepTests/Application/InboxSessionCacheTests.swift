import Foundation
import Testing
@testable import InboxSweep

/// What a relaunch does with a window stored by the previous launch.
///
/// The point of the cache is that reopening the app does not re-read the mailbox, so most of
/// these assert on what was *not* requested as much as on what is shown.
@MainActor
@Suite("Inbox session cache")
struct InboxSessionCacheTests {

    // MARK: - Fixtures

    // `nonisolated` because the suite is `@MainActor` but these are read from the
    // `@Sendable` clock closure handed to the session under test.
    nonisolated private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    nonisolated private static let savedAt = epoch.addingTimeInterval(-7_200)

    private func message(_ id: String, from: String, hours: Double, unread: Bool = false) -> MailMessage {
        MailMessage(
            id: MailMessageID(id),
            sender: EmailAddressParser.parse(from),
            subject: "Subject \(id)",
            receivedAt: Self.epoch.addingTimeInterval(hours * 3600),
            labels: unread ? [.inbox, .unread] : [.inbox],
            hasListUnsubscribeHeader: unread
        )
    }

    private func storedMessages() -> [MailMessage] {
        [
            message("1", from: "Newsletter <newsletter@example.com>", hours: 4, unread: true),
            message("2", from: "newsletter@example.com", hours: 3),
            message("3", from: "newsletter@example.com", hours: 2, unread: true),
            message("4", from: "Jordan <person@example.net>", hours: 1),
        ]
    }

    private func storedWindow(
        nextPageToken: MailPageToken? = nil,
        senders: [SenderSummary]? = nil,
        messages: [MailMessage]? = nil
    ) -> CachedInbox {
        let messages = messages ?? storedMessages()
        return CachedInbox(
            account: .testAccount,
            messages: messages,
            senders: senders ?? SenderAggregator.aggregate(messages),
            nextPageToken: nextPageToken,
            savedAt: Self.savedAt
        )
    }

    private func freshPage(nextPageToken: String? = nil) -> MailMessagePage {
        MailMessagePage(
            messages: [
                message("9", from: "alerts@example.org", hours: 9),
                message("10", from: "alerts@example.org", hours: 8),
            ],
            nextPageToken: nextPageToken.map(MailPageToken.init)
        )
    }

    /// A second page of *different* messages.
    ///
    /// Distinct identifiers on purpose: the session deduplicates across page boundaries, so a
    /// second page that repeated the first would correctly add nothing and this fixture would
    /// be testing the deduplicator rather than the cache.
    private func secondFreshPage(nextPageToken: String? = nil) -> MailMessagePage {
        MailMessagePage(
            messages: [
                message("11", from: "alerts@example.org", hours: 7),
                message("12", from: "alerts@example.org", hours: 6),
            ],
            nextPageToken: nextPageToken.map(MailPageToken.init)
        )
    }

    // MARK: - Restoring from the cache

    @Test("A relaunch shows the stored window without re-reading the mailbox")
    func restoresFromCacheWithoutFetching() async throws {
        let cache = RecordingInboxCache(seeded: storedWindow())
        let provider = StubMailProvider(fetch: .pages([freshPage()]), restorable: .connected(.testAccount))
        let model = InboxSessionModel(provider: provider, cache: cache)

        await model.restore().value

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.loadedMessageCount == 4)
        #expect(snapshot.senderCount == 2)
        #expect(snapshot.senders.first?.sender.address == "newsletter@example.com")
        #expect(await provider.fetchCallCount == 0, "A restored window must not cost a fetch")
    }

    @Test("A restored window says when it was read, so it isn't mistaken for fresh mail")
    func labelsRestoredWindows() async throws {
        let cache = RecordingInboxCache(seeded: storedWindow())
        let model = InboxSessionModel(
            provider: StubMailProvider(restorable: .connected(.testAccount)),
            cache: cache
        )

        await model.restore().value

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.cachedAt == Self.savedAt)
        #expect(snapshot.isRestoredFromCache)
    }

    @Test("A window read this launch is not labelled as restored")
    func doesNotLabelFreshWindows() async throws {
        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .pages([freshPage()])),
            cache: RecordingInboxCache()
        )

        await model.connect().value

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.cachedAt == nil)
        #expect(!snapshot.isRestoredFromCache)
    }

    @Test("Nothing stored means the window is fetched as before")
    func fetchesWhenNothingIsStored() async throws {
        let provider = StubMailProvider(fetch: .pages([freshPage()]), restorable: .connected(.testAccount))
        let model = InboxSessionModel(provider: provider, cache: RecordingInboxCache())

        await model.restore().value

        #expect(try #require(model.state.snapshot).loadedMessageCount == 2)
        #expect(await provider.fetchCallCount == 1)
    }

    @Test("A stored window with no messages in it is not worth showing")
    func ignoresAnEmptyStoredWindow() async throws {
        let cache = RecordingInboxCache(seeded: storedWindow(messages: []))
        let provider = StubMailProvider(fetch: .pages([freshPage()]), restorable: .connected(.testAccount))
        let model = InboxSessionModel(provider: provider, cache: cache)

        await model.restore().value

        #expect(await provider.fetchCallCount == 1)
        #expect(try #require(model.state.snapshot).loadedMessageCount == 2)
    }

    @Test("A stored window is only read for the account that was restored")
    func doesNotShowAnotherAccountsWindow() async throws {
        let otherAccount = MailAccount(
            emailAddress: EmailAddressParser.parse("someone.else@example.org"),
            providerDisplayName: "Stub"
        )
        let cache = RecordingInboxCache(seeded: storedWindow())
        let provider = StubMailProvider(fetch: .pages([freshPage()]), restorable: .connected(otherAccount))
        let model = InboxSessionModel(provider: provider, cache: cache)

        await model.restore().value

        #expect(await provider.fetchCallCount == 1, "The other account's window must not be reused")
        #expect(try #require(model.state.snapshot).loadedMessageCount == 2)
    }

    @Test("Stored summaries that disagree with their messages are rebuilt, not shown")
    func rebuildsDivergedSummaries() async throws {
        // A file whose summaries describe only part of its messages — a half-written save, or
        // one from a build that aggregated differently.
        let messages = storedMessages()
        let cache = RecordingInboxCache(seeded: storedWindow(
            senders: SenderAggregator.aggregate(Array(messages.prefix(1))),
            messages: messages
        ))
        let model = InboxSessionModel(
            provider: StubMailProvider(restorable: .connected(.testAccount)),
            cache: cache
        )

        await model.restore().value

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.loadedMessageCount == 4)
        #expect(snapshot.senderCount == 2, "Summaries should have been rebuilt from the messages")
        #expect(snapshot.senders.first?.messageCount == 3)
    }

    @Test("A restored window is re-sorted without going back to the provider")
    func restoredWindowResortsLocally() async throws {
        let cache = RecordingInboxCache(seeded: storedWindow())
        let provider = StubMailProvider(restorable: .connected(.testAccount))
        let model = InboxSessionModel(provider: provider, cache: cache)
        await model.restore().value

        model.sortOrder = .senderName

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.senders.first?.sender.displayValue == "Jordan")
        #expect(snapshot.isRestoredFromCache, "Re-sorting does not make a restored window fresh")
        #expect(await provider.fetchCallCount == 0)
    }

    // MARK: - Pagination across a relaunch

    @Test("Loading more after a relaunch continues from the stored cursor")
    func continuesPaginationAfterRelaunch() async throws {
        let cache = RecordingInboxCache(seeded: storedWindow(nextPageToken: MailPageToken("page-2")))
        let provider = StubMailProvider(fetch: .pages([freshPage()]), restorable: .connected(.testAccount))
        let model = InboxSessionModel(provider: provider, cache: cache)

        await model.restore().value
        #expect(try #require(model.state.snapshot).hasMoreMessages)

        await model.loadMore().value

        #expect(await provider.fetchRequests.map(\.pageToken) == [MailPageToken("page-2")])
        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.loadedMessageCount == 6, "The new page extends the restored window")
        #expect(snapshot.senderCount == 3)
    }

    @Test("A restored window with no stored cursor offers no further pages")
    func exhaustedWindowStaysExhausted() async throws {
        let cache = RecordingInboxCache(seeded: storedWindow(nextPageToken: nil))
        let provider = StubMailProvider(restorable: .connected(.testAccount))
        let model = InboxSessionModel(provider: provider, cache: cache)

        await model.restore().value
        await model.loadMore().value

        #expect(!(try #require(model.state.snapshot).hasMoreMessages))
        #expect(await provider.fetchCallCount == 0)
    }

    @Test("Extending a restored window does not present the older pages as freshly read")
    func extendedWindowStaysLabelledAsRestored() async throws {
        let cache = RecordingInboxCache(seeded: storedWindow(nextPageToken: MailPageToken("page-2")))
        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .pages([freshPage()]), restorable: .connected(.testAccount)),
            cache: cache
        )

        await model.restore().value
        await model.loadMore().value

        #expect(try #require(model.state.snapshot).isRestoredFromCache)
    }

    // MARK: - Writing the cache

    @Test("A loaded window is stored for the next launch")
    func savesTheLoadedWindow() async throws {
        let cache = RecordingInboxCache()
        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .pages([freshPage(nextPageToken: "page-2")])),
            cache: cache,
            now: { Self.epoch }
        )

        await model.connect().value

        let saved = try #require(await cache.lastSaved)
        #expect(saved.account == .testAccount)
        #expect(saved.messages.count == 2)
        #expect(saved.senders.count == 1)
        #expect(saved.nextPageToken == MailPageToken("page-2"))
        #expect(saved.savedAt == Self.epoch)
        #expect(saved.summariesMatchMessages)
    }

    @Test("An extra page is stored too, so a relaunch keeps everything that was loaded")
    func savesTheExtendedWindow() async throws {
        let cache = RecordingInboxCache()
        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .pages([freshPage(nextPageToken: "page-2"), secondFreshPage()])),
            cache: cache
        )

        await model.connect().value
        await model.loadMore().value

        #expect(try #require(await cache.lastSaved).messages.count == 4)
    }

    @Test("Reloading replaces the stored window and drops the restored label")
    func reloadReplacesTheStoredWindow() async throws {
        let cache = RecordingInboxCache(seeded: storedWindow())
        let provider = StubMailProvider(fetch: .pages([freshPage()]), restorable: .connected(.testAccount))
        let model = InboxSessionModel(provider: provider, cache: cache)
        await model.restore().value

        await model.reload().value

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.loadedMessageCount == 2)
        #expect(!snapshot.isRestoredFromCache)
        #expect(try #require(await cache.lastSaved).messages.count == 2)
        #expect(await provider.fetchCallCount == 1)
    }

    @Test("A failed load leaves the stored window alone")
    func failedLoadDoesNotTouchTheCache() async throws {
        let cache = RecordingInboxCache(seeded: storedWindow())
        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .fails(.network(reason: "Offline."))),
            cache: cache
        )

        await model.connect().value

        #expect(model.state == .failed(.network(reason: "Offline."), account: .testAccount))
        #expect(await cache.saveCallCount == 0)
        #expect(await cache.storedWindow(for: .testAccount) != nil)
    }

    // MARK: - Signing out

    @Test("Disconnecting deletes the stored window")
    func disconnectClearsTheCache() async throws {
        let cache = RecordingInboxCache()
        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .pages([freshPage()])),
            cache: cache
        )
        await model.connect().value
        #expect(await cache.storedWindow(for: .testAccount) != nil)

        await model.disconnect().value

        #expect(await cache.clearCallCount == 1)
        #expect(await cache.storedWindow(for: .testAccount) == nil)
    }

    @Test("Signing out and back in starts from a fresh read, not the deleted window")
    func reconnectAfterDisconnectFetches() async throws {
        let cache = RecordingInboxCache()
        let provider = StubMailProvider(fetch: .pages([freshPage(), freshPage()]))
        let model = InboxSessionModel(provider: provider, cache: cache)

        await model.connect().value
        await model.disconnect().value
        await model.connect().value

        #expect(try #require(model.state.snapshot).loadedMessageCount == 2)
        #expect(!(try #require(model.state.snapshot).isRestoredFromCache))
    }

    // MARK: - Per-sender messages

    @Test("A sender's loaded messages are available newest first")
    func exposesMessagesForASender() async throws {
        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .pages([MailMessagePage(messages: storedMessages())])),
            cache: RecordingInboxCache()
        )
        await model.connect().value

        let messages = model.loadedMessages(forSenderKey: "newsletter@example.com")

        #expect(messages.map(\.id.rawValue) == ["1", "2", "3"])
        #expect(model.loadedMessages(forSenderKey: "person@example.net").count == 1)
    }

    @Test("A sender's messages come back after a relaunch, without a fetch")
    func exposesMessagesForARestoredSender() async throws {
        let cache = RecordingInboxCache(seeded: storedWindow())
        let provider = StubMailProvider(restorable: .connected(.testAccount))
        let model = InboxSessionModel(provider: provider, cache: cache)
        await model.restore().value

        #expect(model.loadedMessages(forSenderKey: "newsletter@example.com").count == 3)
        #expect(await provider.fetchCallCount == 0)
    }

    @Test("Asking for a sender that isn't loaded returns nothing rather than failing")
    func returnsNoMessagesForAnUnknownSender() async {
        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .pages([MailMessagePage(messages: storedMessages())])),
            cache: RecordingInboxCache()
        )
        await model.connect().value

        #expect(model.loadedMessages(forSenderKey: "nobody@example.org").isEmpty)
    }
}

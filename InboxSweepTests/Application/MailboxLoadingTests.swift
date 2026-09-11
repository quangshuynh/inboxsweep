import Foundation
import Testing
@testable import InboxSweep

/// How much of a mailbox the app reads, and what it says about how much that is.
///
/// The proposal engine reasons over the loaded window and nothing else, so the depth of that
/// window is an input to every suggestion on screen. These cases pin down the three things that
/// makes true: it is bounded, it is cancellable, and it never claims more coverage than it has.
@MainActor
@Suite("Mailbox loading")
struct MailboxLoadingTests {

    // MARK: - Fixtures

    nonisolated private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// `count` messages with sequential identifiers starting at `startingAt`.
    private func page(
        _ count: Int,
        startingAt: Int,
        nextPageToken: String?,
        from: String = "newsletter@example.com",
        labels: Set<MailLabel> = [.inbox]
    ) -> MailMessagePage {
        MailMessagePage(
            messages: (0..<count).map { offset in
                let index = startingAt + offset
                return MailMessage(
                    id: MailMessageID("m-\(index)"),
                    sender: EmailAddressParser.parse(from),
                    subject: "Subject \(index)",
                    receivedAt: Self.epoch.addingTimeInterval(-Double(index) * 3600),
                    labels: labels,
                    hasListUnsubscribeHeader: true
                )
            },
            nextPageToken: nextPageToken.map(MailPageToken.init)
        )
    }

    /// A provider with `pageCount` pages of `pageSize`, the last one ending the run.
    private func paginatedProvider(pageCount: Int, pageSize: Int) -> StubMailProvider {
        let pages = (0..<pageCount).map { index in
            page(
                pageSize,
                startingAt: index * pageSize,
                nextPageToken: index == pageCount - 1 ? nil : "page-\(index + 2)"
            )
        }
        return StubMailProvider(fetch: .pages(pages))
    }

    // MARK: - Depth

    @Test("A deep load keeps reading pages until the chosen depth is reached")
    func loadsToDepth() async throws {
        let provider = paginatedProvider(pageCount: 6, pageSize: 50)
        let model = InboxSessionModel(
            provider: provider,
            fetchRequest: MailFetchRequest(limit: 50),
            loadDepth: MailboxLoadDepth(messageLimit: 200, pageSize: 50)
        )

        await model.connect().value
        #expect(try #require(model.state.snapshot).loadedMessageCount == 50)

        await model.loadToDepth().value

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.loadedMessageCount == 200)
        #expect(snapshot.isLoadingMore == false)
        // Four pages of fifty, and not a request more: the depth is a ceiling, not a hint.
        #expect(await provider.fetchCallCount == 4)
    }

    @Test("A deep load stops early when the provider runs out, without reporting more to come")
    func stopsWhenProviderIsExhausted() async throws {
        let provider = paginatedProvider(pageCount: 3, pageSize: 20)
        let model = InboxSessionModel(
            provider: provider,
            fetchRequest: MailFetchRequest(limit: 20),
            loadDepth: MailboxLoadDepth(messageLimit: 1_000, pageSize: 20)
        )

        await model.connect().value
        await model.loadToDepth().value

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.loadedMessageCount == 60)
        #expect(snapshot.hasMoreMessages == false)
        #expect(await provider.fetchCallCount == 3)
    }

    @Test("No depth can read past the documented safety limit")
    func honoursTheSafetyLimit() {
        // Constructed rather than chosen from the menu, because the ceiling has to hold against
        // a value someone passed in, not only against the four the UI offers.
        let absurd = MailboxLoadDepth(messageLimit: 10_000_000)
        #expect(absurd.messageLimit == MailboxLoadDepth.safetyLimit)

        for depth in MailboxLoadDepth.offered {
            #expect(depth.messageLimit <= MailboxLoadDepth.safetyLimit)
            #expect(depth.pageSize <= 500, "A page larger than Gmail's own maximum")
        }
    }

    @Test("A deep load makes a bounded number of requests even when the provider never runs out")
    func boundsRequestsAgainstAnEndlessProvider() async throws {
        // A provider that always hands back a cursor and never any messages. Without a page
        // budget this is an infinite loop pointed at somebody's Gmail quota.
        let endless = StubMailProvider(
            fetch: .pages(Array(repeating: page(0, startingAt: 0, nextPageToken: "always-more"), count: 200))
        )
        let model = InboxSessionModel(
            provider: endless,
            fetchRequest: MailFetchRequest(limit: 10),
            loadDepth: MailboxLoadDepth(messageLimit: 100, pageSize: 10)
        )

        await model.connect().value
        await model.loadToDepth().value

        // One request for the first page, then at most the budget. The exact number matters
        // less than the fact that there is one.
        #expect(await endless.fetchCallCount <= 13)
    }

    @Test("Loading more reads a single page, whatever the chosen depth is")
    func loadMoreStaysOnePage() async throws {
        let provider = paginatedProvider(pageCount: 8, pageSize: 25)
        let model = InboxSessionModel(
            provider: provider,
            fetchRequest: MailFetchRequest(limit: 25),
            loadDepth: MailboxLoadDepth(messageLimit: 2_000, pageSize: 25)
        )

        await model.connect().value
        await model.loadMore().value

        #expect(try #require(model.state.snapshot).loadedMessageCount == 50)
        #expect(await provider.fetchCallCount == 2)
    }

    // MARK: - Deduplication

    @Test("A message listed on both sides of a page boundary is counted once")
    func deduplicatesAcrossPages() async throws {
        // Gmail genuinely does this. The fetcher removes duplicates within a page; only the
        // session can see across one.
        let first = page(10, startingAt: 0, nextPageToken: "page-2")
        let overlapping = page(10, startingAt: 8, nextPageToken: nil)
        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .pages([first, overlapping])),
            fetchRequest: MailFetchRequest(limit: 10),
            loadDepth: MailboxLoadDepth(messageLimit: 100, pageSize: 10)
        )

        await model.connect().value
        await model.loadToDepth().value

        let snapshot = try #require(model.state.snapshot)
        // 0...17, not 0...9 plus 8...17.
        #expect(snapshot.loadedMessageCount == 18)
        #expect(snapshot.senders.reduce(0) { $0 + $1.messageCount } == 18)

        let loaded = model.loadedMessages(forSenderKey: try #require(snapshot.senders.first).id)
        #expect(Set(loaded.map(\.id)).count == loaded.count, "A message appeared twice in a sender's list")
    }

    @Test("A page that is entirely duplicates does not stall the load or inflate the count")
    func toleratesAWhollyDuplicatePage() async throws {
        let first = page(10, startingAt: 0, nextPageToken: "page-2")
        let repeated = page(10, startingAt: 0, nextPageToken: "page-3")
        let fresh = page(5, startingAt: 10, nextPageToken: nil)
        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .pages([first, repeated, fresh])),
            fetchRequest: MailFetchRequest(limit: 10),
            loadDepth: MailboxLoadDepth(messageLimit: 100, pageSize: 10)
        )

        await model.connect().value
        await model.loadToDepth().value

        #expect(try #require(model.state.snapshot).loadedMessageCount == 15)
    }

    // MARK: - Cancellation

    @Test("Stopping a deep load keeps every page it already read")
    func cancellationKeepsWhatWasLoaded() async throws {
        let provider = StubMailProvider(fetch: .pages([page(30, startingAt: 0, nextPageToken: "page-2")]))
        let model = InboxSessionModel(
            provider: provider,
            fetchRequest: MailFetchRequest(limit: 30),
            loadDepth: MailboxLoadDepth(messageLimit: 500, pageSize: 30)
        )

        await model.connect().value
        // Every further page stalls, so the deep load is guaranteed to be in flight.
        await provider.setFetchBehavior(.stalls)

        let deepLoad = model.loadToDepth()
        model.cancel()
        await deepLoad.value

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.loadedMessageCount == 30, "Cancelling threw away work the user waited for")
        #expect(snapshot.isLoadingMore == false, "A cancelled load still claimed to be loading")
    }

    @Test("A failed page leaves the window intact rather than emptying the dashboard")
    func failedPageKeepsTheWindow() async throws {
        let provider = StubMailProvider(fetch: .pages([page(20, startingAt: 0, nextPageToken: "page-2")]))
        let model = InboxSessionModel(
            provider: provider,
            fetchRequest: MailFetchRequest(limit: 20),
            loadDepth: MailboxLoadDepth(messageLimit: 500, pageSize: 20)
        )

        await model.connect().value
        await provider.setFetchBehavior(.fails(.network(reason: "Offline.")))
        await model.loadToDepth().value

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.loadedMessageCount == 20)
        #expect(snapshot.isLoadingMore == false)
    }

    // MARK: - Scope

    @Test("Changing the scope re-reads rather than mixing two scopes in one window")
    func changingScopeReloads() async throws {
        let provider = StubMailProvider(fetch: .pages([
            page(10, startingAt: 0, nextPageToken: nil),
            page(4, startingAt: 100, nextPageToken: nil, from: "shop@example.com"),
        ]))
        let model = InboxSessionModel(provider: provider, fetchRequest: MailFetchRequest(limit: 10))

        await model.connect().value
        #expect(try #require(model.state.snapshot).scope == .inbox)

        model.scope = .promotions
        // The `didSet` starts a load; awaiting a fresh no-op task is not enough, so drain by
        // awaiting the reload the property change kicked off.
        await model.reload().value

        let snapshot = try #require(model.state.snapshot)
        #expect(snapshot.scope == .promotions)
        // The inbox window is gone, not appended to.
        #expect(snapshot.loadedMessageCount <= 10)
        let requestedScopes = await provider.fetchRequests.map(\.scope)
        #expect(requestedScopes.contains(.promotions))
    }

    @Test("Setting the same scope again does not cost a request")
    func settingTheSameScopeIsFree() async throws {
        let provider = StubMailProvider(fetch: .pages([page(10, startingAt: 0, nextPageToken: nil)]))
        let model = InboxSessionModel(provider: provider, fetchRequest: MailFetchRequest(limit: 10))

        await model.connect().value
        let before = await provider.fetchCallCount
        model.scope = .inbox

        #expect(await provider.fetchCallCount == before)
    }

    @Test("Every offered scope maps to a Gmail label, or to no filter at all")
    func everyScopeIsExpressible() {
        for scope in MailboxScope.offered {
            let url = GmailAPIEndpoint.listMessages(limit: 10, pageToken: nil, scope: scope).url
            let labelIDs = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.filter { $0.name == "labelIds" }.compactMap(\.value) ?? []

            switch scope {
            case .allMail:
                #expect(labelIDs.isEmpty, "All mail must not be filtered")
            default:
                #expect(labelIDs.count == 1, "\(scope.displayName) did not resolve to one label")
            }
            // The narrow scope forbids `q=`, and nothing here may reintroduce it.
            #expect(!url.absoluteString.contains("q="))
        }
    }

    // MARK: - Coverage reporting

    @Test("Coverage says how much was read, and never implies more")
    func coverageStatesWhatWasRead() async throws {
        let provider = paginatedProvider(pageCount: 4, pageSize: 25)
        let model = InboxSessionModel(provider: provider, fetchRequest: MailFetchRequest(limit: 25))

        await model.connect().value
        let partial = try #require(model.state.snapshot)

        #expect(partial.coverageHeadline == "25 messages loaded")
        #expect(partial.coverageDetail.contains("More messages are available"))
        #expect(!partial.coverageDetail.contains("everything"))

        model.loadDepth = MailboxLoadDepth(messageLimit: 1_000, pageSize: 25)
        await model.loadToDepth().value
        let complete = try #require(model.state.snapshot)

        #expect(complete.coverageHeadline == "100 messages loaded")
        #expect(complete.coverageDetail.contains("everything InboxSweep could list"))
        #expect(complete.hasMoreMessages == false)
    }

    @Test("Coverage names the scope it describes rather than calling everything the mailbox")
    func coverageNamesItsScope() {
        let inbox = InboxSnapshot(
            account: .testAccount,
            loadedMessageCount: 10,
            senders: [],
            sortOrder: .messageVolume,
            scope: .inbox,
            hasMoreMessages: true,
            isLoadingMore: false
        )
        let promotions = InboxSnapshot(
            account: .testAccount,
            loadedMessageCount: 10,
            senders: [],
            sortOrder: .messageVolume,
            scope: .promotions,
            hasMoreMessages: true,
            isLoadingMore: false
        )

        #expect(inbox.coverageDetail.contains("your inbox"))
        #expect(promotions.coverageDetail.contains("Promotions category"))
        #expect(!promotions.coverageDetail.contains("your mailbox"))
    }

    @Test("A single message is described in the singular")
    func coverageAgreesInNumber() {
        let one = InboxSnapshot(
            account: .testAccount,
            loadedMessageCount: 1,
            senders: [],
            sortOrder: .messageVolume,
            hasMoreMessages: false,
            isLoadingMore: false
        )
        #expect(one.coverageHeadline == "1 message loaded")
    }

    // MARK: - Recalculation

    @Test("A proposal changes as more evidence arrives")
    func proposalsRecomputeAsPagesArrive() async throws {
        // Page one: a plain run of promotional mail, which the rules read as clutter.
        // Page two: the same sender, starred and marked Important, which protects them.
        let first = MailMessagePage(
            messages: ProposalFixtures.promotionalSender(count: 12),
            nextPageToken: MailPageToken("page-2")
        )
        let sender = try #require(first.messages.first).sender
        let second = MailMessagePage(
            messages: (0..<3).map { index in
                MailMessage(
                    id: MailMessageID("protective-\(index)"),
                    sender: sender,
                    subject: "Your order #\(index) receipt",
                    receivedAt: Self.epoch.addingTimeInterval(-Double(index) * 86_400),
                    labels: [.inbox, .starred]
                )
            },
            nextPageToken: nil
        )

        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .pages([first, second])),
            fetchRequest: MailFetchRequest(limit: 12),
            loadDepth: MailboxLoadDepth(messageLimit: 100, pageSize: 12)
        )

        await model.connect().value
        let key = sender.groupingKey
        let before = try #require(model.proposal(forSenderKey: key))
        #expect(before.suggestsCleanup)
        #expect(!before.isProtected)

        await model.loadToDepth().value

        let after = try #require(model.proposal(forSenderKey: key))
        #expect(after.isProtected, "A starred message arrived and the verdict did not move")
        #expect(!after.suggestsCleanup, "Cleanup was still proposed for a protected sender")
        #expect(after.loadedMessageCount == 15, "The proposal's own counts went stale")
    }

    @Test("Extending the window updates the counts a proposal reports, not just its verdict")
    func proposalFactsTrackTheWindow() async throws {
        let first = MailMessagePage(
            messages: ProposalFixtures.newsletterSender(count: 6),
            nextPageToken: MailPageToken("page-2")
        )
        let sender = try #require(first.messages.first).sender
        let second = MailMessagePage(
            messages: ProposalFixtures.newsletterSender(count: 6).map { message in
                MailMessage(
                    id: MailMessageID("second-\(message.id.rawValue)"),
                    sender: sender,
                    subject: message.subject,
                    receivedAt: message.receivedAt.addingTimeInterval(-30 * 86_400),
                    labels: message.labels,
                    hasListUnsubscribeHeader: message.hasListUnsubscribeHeader
                )
            },
            nextPageToken: nil
        )

        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .pages([first, second])),
            fetchRequest: MailFetchRequest(limit: 6),
            loadDepth: MailboxLoadDepth(messageLimit: 100, pageSize: 6)
        )

        await model.connect().value
        #expect(try #require(model.proposal(forSenderKey: sender.groupingKey)).loadedMessageCount == 6)

        await model.loadToDepth().value

        let after = try #require(model.proposal(forSenderKey: sender.groupingKey))
        #expect(after.loadedMessageCount == 12)
        // The window now reaches a month further back, and the proposal says so.
        #expect(after.loadedWindowSpan > 25 * 86_400)
    }

    @Test("A plan's window figures follow the loaded window rather than the first page")
    func planWindowTracksTheLoad() async throws {
        let provider = paginatedProvider(pageCount: 3, pageSize: 20)
        let model = InboxSessionModel(
            provider: provider,
            fetchRequest: MailFetchRequest(limit: 20),
            loadDepth: MailboxLoadDepth(messageLimit: 1_000, pageSize: 20)
        )

        await model.connect().value
        #expect(model.cleanupPlan(for: []).window.loadedMessageCount == 20)
        #expect(model.cleanupPlan(for: []).window.isPartial)

        await model.loadToDepth().value

        let window = model.cleanupPlan(for: []).window
        #expect(window.loadedMessageCount == 60)
        #expect(!window.isPartial)
    }
}

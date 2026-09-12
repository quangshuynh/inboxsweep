import Foundation
import Testing
@testable import InboxSweep

/// Looking at the individual messages behind a proposal, and at what a plan would do to each.
///
/// The point of this screen is auditability: a count nobody can check is a claim, and a named
/// list is evidence. So the cases that matter most here are the ones tying the two together:
/// the per-message verdicts must add up to exactly the totals shown beside them.
@MainActor
@Suite("Message review")
struct MessageReviewTests {

    // MARK: - Fixtures

    nonisolated private static let epoch = ProposalFixtures.epoch

    /// A promotional sender with a starred message and an order receipt mixed in.
    private func mixedSender() -> [MailMessage] {
        var messages = ProposalFixtures.messages(
            from: "Storefront Deals <deals@example.com>",
            subjects: ProposalFixtures.neutralSubjects(10, prefix: "Weekend sale"),
            hoursApart: 24,
            labels: [.inbox, .categoryPromotions],
            listUnsubscribe: true,
            unreadCount: 10
        )
        messages.append(
            MailMessage(
                id: MailMessageID("starred-1"),
                sender: EmailAddressParser.parse("Storefront Deals <deals@example.com>"),
                subject: "A sale worth remembering",
                receivedAt: Self.epoch.addingTimeInterval(-20 * 86_400),
                labels: [.inbox, .categoryPromotions, .starred]
            )
        )
        messages.append(
            MailMessage(
                id: MailMessageID("receipt-1"),
                sender: EmailAddressParser.parse("Storefront Deals <deals@example.com>"),
                subject: "Your order receipt",
                receivedAt: Self.epoch.addingTimeInterval(-21 * 86_400),
                labels: [.inbox, .categoryPromotions]
            )
        )
        return messages
    }

    private func model(with messages: [MailMessage]) async -> InboxSessionModel {
        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .pages([MailMessagePage(messages: messages)])),
            fetchRequest: MailFetchRequest(limit: messages.count),
            now: { Self.epoch }
        )
        await model.connect().value
        return model
    }

    private var senderKey: SenderSummary.ID {
        EmailAddressParser.parse("deals@example.com").groupingKey
    }

    // MARK: - Which messages

    @Test("A review lists exactly the loaded messages from that sender")
    func listsTheSendersMessages() async throws {
        let messages = mixedSender() + ProposalFixtures.newsletterSender(count: 5)
        let model = await model(with: messages)

        let reviewed = model.reviewedMessages(forSenderKey: senderKey)

        #expect(reviewed.count == 12)
        #expect(reviewed.allSatisfy { $0.message.sender.groupingKey == senderKey })
        #expect(Set(reviewed.map(\.id)).count == reviewed.count)
    }

    @Test("A sender with nothing loaded reviews as empty rather than failing")
    func emptySenderReviewsEmpty() async throws {
        let model = await model(with: ProposalFixtures.newsletterSender(count: 4))

        #expect(model.reviewedMessages(forSenderKey: "nobody@example.invalid").isEmpty)
        #expect(model.reviewedMessages(forSenderKey: "nobody@example.invalid", under: .keepNewest(count: 5)).isEmpty)
    }

    @Test("A review shows the metadata the dashboard has and no message content")
    func reviewCarriesMetadataOnly() async throws {
        let model = await model(with: mixedSender())
        let row = try #require(model.reviewedMessages(forSenderKey: senderKey).first)

        // Everything a reviewer needs is present…
        #expect(row.message.subject != nil)
        #expect(row.message.receivedAt > .distantPast)
        #expect(row.categoryLabels.contains(.categoryPromotions))

        // …and there is nowhere for a body to be, which is structural rather than a promise.
        let propertyNames = Set(Mirror(reflecting: row.message).children.compactMap(\.label))
        #expect(propertyNames.isDisjoint(with: ["body", "snippet", "payload", "html", "raw"]))
    }

    // MARK: - Protection

    @Test("A message protected on its own merits says so, whatever plan is selected")
    func protectionIsIndependentOfThePlan() async throws {
        let model = await model(with: mixedSender())

        for action in [PlannedCleanupAction?.none, .keepNewest(count: 2), .archiveMessagesOlderThan(days: 1)] {
            let reviewed = model.reviewedMessages(forSenderKey: senderKey, under: action)
            let starred = try #require(reviewed.first { $0.id == MailMessageID("starred-1") })
            #expect(starred.protectionReason == .starred)

            let receipt = try #require(reviewed.first { $0.id == MailMessageID("receipt-1") })
            #expect(receipt.protectionReason?.isProtective == true)
        }
    }

    @Test("An ordinary promotional message raises no protection reason")
    func unprotectedMessagesSayNothing() async throws {
        let model = await model(with: mixedSender())
        let reviewed = model.reviewedMessages(forSenderKey: senderKey)

        #expect(reviewed.contains { $0.protectionReason == nil })
    }

    // MARK: - Plan membership

    @Test("With no plan selected, no message claims a membership")
    func noPlanMeansNoMembership() async throws {
        let model = await model(with: mixedSender())

        #expect(model.reviewedMessages(forSenderKey: senderKey).allSatisfy { $0.membership == nil })
    }

    @Test("Keep-newest retains exactly the newest N and affects the rest, minus the protected")
    func keepNewestMembership() async throws {
        let model = await model(with: mixedSender())
        let reviewed = model.reviewedMessages(
            forSenderKey: senderKey,
            under: .keepNewest(count: 3),
            sortedBy: .newestFirst
        )

        let kept = reviewed.prefix(3)
        #expect(kept.allSatisfy { $0.membership == .retained(.amongNewestKept(count: 3)) })

        // Of the nine below the cut, the starred one and the receipt are held back.
        let rest = reviewed.dropFirst(3)
        #expect(rest.contains { $0.id == MailMessageID("starred-1") && $0.membership == .retained(.starred) })
        #expect(rest.contains { $0.membership?.isAffected == true })
    }

    @Test("An age cutoff retains everything newer than it, for that reason and not for protection")
    func cutoffMembershipNamesTheScopeFirst() async throws {
        let model = await model(with: mixedSender())
        let reviewed = model.reviewedMessages(forSenderKey: senderKey, under: .archiveMessagesOlderThan(days: 5))

        // The starred message is 20 days old, so the cutoff *does* reach it, and protection
        // is what spares it.
        let starred = try #require(reviewed.first { $0.id == MailMessageID("starred-1") })
        #expect(starred.membership == .retained(.starred))

        // A message from two days ago is out of scope entirely. Reporting it as "protected"
        // would claim the app saved something the action was never going to touch.
        let recent = try #require(reviewed.first { $0.message.receivedAt > Self.epoch.addingTimeInterval(-3 * 86_400) })
        #expect(recent.membership == .retained(.newerThanCutoff(days: 5)))
    }

    @Test("Reviewing a subscription moves nothing, and every message says so")
    func subscriptionReviewAffectsNothing() async throws {
        let model = await model(with: mixedSender())
        let reviewed = model.reviewedMessages(forSenderKey: senderKey, under: .reviewSubscription)

        #expect(reviewed.allSatisfy { $0.membership == .retained(.actionMovesNoMessages) })
        #expect(!reviewed.contains { $0.isAffectedByPlan })
    }

    @Test("Per-message verdicts add up to exactly the totals the preview shows")
    func membershipAgreesWithThePlanCounts() async throws {
        let model = await model(with: mixedSender())

        for action in PlannedCleanupAction.offered {
            let plan = model.cleanupPlan(for: [CleanupPlanRequest(senderKey: senderKey, action: action)])
            let entry = try #require(plan.entries.first)
            let reviewed = model.reviewedMessages(forSenderKey: senderKey, under: action)

            #expect(
                reviewed.count(where: \.isAffectedByPlan) == entry.affectedMessageCount,
                "\(action.displayName): the named messages disagree with the count above them"
            )
            #expect(reviewed.count == entry.loadedMessageCount)
            #expect(
                reviewed.count { $0.membership?.isProtected == true } == entry.protectedMessageCount,
                "\(action.displayName): the protected list disagrees with the protected count"
            )
        }
    }

    @Test("Every retained message names one reason, so a retained count is never a residual")
    func everyRetainedMessageHasAReason() async throws {
        let model = await model(with: mixedSender())

        for action in PlannedCleanupAction.offered {
            let reviewed = model.reviewedMessages(forSenderKey: senderKey, under: action)
            for row in reviewed where !row.isAffectedByPlan {
                #expect(row.membership?.reason != nil, "A message stayed put for no stated reason")
            }
        }
    }

    // MARK: - Sorting

    @Test("Newest and oldest are exact reverses of each other")
    func sortsByDate() async throws {
        let model = await model(with: mixedSender())

        let newest = model.reviewedMessages(forSenderKey: senderKey, sortedBy: .newestFirst)
        let oldest = model.reviewedMessages(forSenderKey: senderKey, sortedBy: .oldestFirst)

        #expect(newest.map(\.id) == oldest.reversed().map(\.id))
        #expect(zip(newest, newest.dropFirst()).allSatisfy { $0.message.receivedAt >= $1.message.receivedAt })
        #expect(zip(oldest, oldest.dropFirst()).allSatisfy { $0.message.receivedAt <= $1.message.receivedAt })
    }

    @Test("Unread-first puts every unread message above every read one")
    func sortsUnreadFirst() async throws {
        let model = await model(with: mixedSender())
        let rows = model.reviewedMessages(forSenderKey: senderKey, sortedBy: .unreadFirst)

        let firstRead = rows.firstIndex { !$0.message.isUnread } ?? rows.count
        #expect(rows.prefix(firstRead).allSatisfy { $0.message.isUnread })
        #expect(rows.dropFirst(firstRead).allSatisfy { !$0.message.isUnread })
    }

    @Test("Subject order is alphabetical and case-insensitive")
    func sortsBySubject() async throws {
        let model = await model(with: mixedSender())
        let subjects = model.reviewedMessages(forSenderKey: senderKey, sortedBy: .subject)
            .map { $0.message.subject ?? "" }

        #expect(zip(subjects, subjects.dropFirst()).allSatisfy {
            $0.caseInsensitiveCompare($1) != .orderedDescending
        })
    }

    @Test("Every order is total, so an identical window never reshuffles")
    func everySortIsStable() async throws {
        // Two messages sharing a timestamp and a subject: without an identifier tiebreak, their
        // relative order would be whatever the sort algorithm felt like that run.
        let sender = EmailAddressParser.parse("deals@example.com")
        let tied = (0..<4).map { index in
            MailMessage(
                id: MailMessageID("tie-\(index)"),
                sender: sender,
                subject: "Identical subject",
                receivedAt: Self.epoch,
                labels: [.inbox]
            )
        }
        let model = await model(with: tied)

        for order in MessageReviewSortOrder.allCases {
            let first = model.reviewedMessages(forSenderKey: senderKey, sortedBy: order).map(\.id)
            let second = model.reviewedMessages(forSenderKey: senderKey, sortedBy: order).map(\.id)
            #expect(first == second, "\(order.displayName) is not a total order")
        }
    }

    // MARK: - Recalculation

    @Test("A review reflects the window as it is now, not as it was when it opened")
    func reviewTracksTheWindow() async throws {
        let first = MailMessagePage(
            messages: ProposalFixtures.promotionalSender(count: 6),
            nextPageToken: MailPageToken("page-2")
        )
        let sender = try #require(first.messages.first).sender
        let second = MailMessagePage(
            messages: (0..<4).map { index in
                MailMessage(
                    id: MailMessageID("later-\(index)"),
                    sender: sender,
                    subject: "Older sale \(index)",
                    receivedAt: Self.epoch.addingTimeInterval(-Double(index + 40) * 86_400),
                    labels: [.inbox, .categoryPromotions]
                )
            },
            nextPageToken: nil
        )

        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .pages([first, second])),
            fetchRequest: MailFetchRequest(limit: 6),
            loadDepth: MailboxLoadDepth(messageLimit: 100, pageSize: 6),
            now: { Self.epoch }
        )
        await model.connect().value

        let key = sender.groupingKey
        #expect(model.reviewedMessages(forSenderKey: key).count == 6)

        await model.loadToDepth().value

        #expect(model.reviewedMessages(forSenderKey: key).count == 10)
    }
}

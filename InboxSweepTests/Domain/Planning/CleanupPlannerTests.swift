import Foundation
import Testing
@testable import InboxSweep

/// What a dry-run preview says a cleanup would reach.
///
/// The arithmetic is the point: a preview that overstates what it would touch, or that reports
/// a retained count without saying which messages it means, is worse than no preview at all.
@Suite("Dry-run cleanup planner")
struct CleanupPlannerTests {

    private static let now = ProposalFixtures.epoch.addingTimeInterval(ProposalFixtures.hour)

    private let window = CleanupPlanWindow(loadedMessageCount: 250, hasMoreBeyondWindow: true, scope: .inbox)
    private let completeWindow = CleanupPlanWindow(loadedMessageCount: 40, hasMoreBeyondWindow: false, scope: .inbox)

    /// Builds a plan over one or more senders' messages.
    private func plan(
        _ requests: [CleanupPlanRequest],
        senders: [[MailMessage]],
        window: CleanupPlanWindow? = nil
    ) -> CleanupPlan {
        var messagesBySender: [SenderSummary.ID: [MailMessage]] = [:]
        var proposals: [SenderSummary.ID: SenderCleanupProposal] = [:]

        for messages in senders {
            guard let key = messages.first?.sender.groupingKey else { continue }
            messagesBySender[key, default: []] += messages
        }
        for (key, messages) in messagesBySender {
            proposals[key] = ProposalFixtures.proposal(for: messages)
        }

        return CleanupPlanner.plan(
            requests: requests,
            messagesBySender: messagesBySender,
            proposals: proposals,
            window: window ?? self.window,
            referenceDate: Self.now
        )
    }

    /// 20 daily messages: index 0 is one hour before `now`, index 19 is 19 days older.
    private func dailySender(
        _ address: String = "deals@example.com",
        count: Int = 20,
        starredCount: Int = 0,
        importantCount: Int = 0,
        subjects: [String]? = nil,
        idPrefix: String = "m"
    ) -> [MailMessage] {
        ProposalFixtures.messages(
            from: address,
            subjects: subjects ?? ProposalFixtures.neutralSubjects(count, prefix: "Weekend sale"),
            hoursApart: 24,
            labels: [.inbox, .categoryPromotions],
            listUnsubscribe: true,
            unreadCount: count,
            starredCount: starredCount,
            importantCount: importantCount,
            idPrefix: idPrefix
        )
    }

    private func key(_ messages: [MailMessage]) -> SenderSummary.ID {
        messages[0].sender.groupingKey
    }

    // MARK: - Counting

    @Test("Only messages older than the cutoff are counted as affected")
    func countsOnlyMessagesPastTheCutoff() throws {
        let messages = dailySender()
        let result = plan(
            [CleanupPlanRequest(senderKey: key(messages), action: .archiveMessagesOlderThan(days: 10))],
            senders: [messages]
        )

        let entry = try #require(result.entries.first)
        // Message n arrived n days + 1 hour before `now`, so 0...9 are inside the 10-day
        // cutoff and 10...19 are outside it.
        #expect(entry.loadedMessageCount == 20)
        #expect(entry.affectedMessageCount == 10)
        #expect(entry.retainedMessageCount == 10)
        #expect(entry.exclusions.contains { $0.reason == .newerThanCutoff(days: 10) })
    }

    @Test("Retained messages are always accounted for by a stated reason")
    func retainedCountIsFullyExplained() {
        let messages = dailySender(starredCount: 2)
        let result = plan(
            [CleanupPlanRequest(senderKey: key(messages), action: .archiveMessagesOlderThan(days: 5))],
            senders: [messages]
        )

        for entry in result.entries {
            #expect(entry.exclusions.reduce(0) { $0 + $1.messageCount } == entry.retainedMessageCount)
            #expect(entry.exclusions.allSatisfy { !$0.explanation.isEmpty })
        }
    }

    @Test("Protected messages inside the action's reach are excluded and named")
    func excludesProtectedMessagesWithinReach() throws {
        // Starred and Important land on the *newest* messages, so put them out past the cutoff
        // where the action would otherwise have taken them.
        var subjects = ProposalFixtures.neutralSubjects(20, prefix: "Weekend sale")
        subjects[15] = "Your order has shipped"
        subjects[16] = "Re: my order"
        let messages = ProposalFixtures.messages(
            from: "deals@example.com",
            subjects: subjects,
            hoursApart: 24,
            labels: [.inbox, .categoryPromotions],
            listUnsubscribe: true
        )

        let result = plan(
            [CleanupPlanRequest(senderKey: key(messages), action: .archiveMessagesOlderThan(days: 10))],
            senders: [messages]
        )
        let entry = try #require(result.entries.first)

        #expect(entry.affectedMessageCount == 8, "The two protected messages are held back")
        #expect(entry.protectedMessageCount == 2)
        #expect(entry.protectiveExclusions.map(\.reason).contains(.protectedTopic(.receiptOrOrder)))
        #expect(entry.protectiveExclusions.map(\.reason).contains(.replyLikeSubject))
    }

    @Test("A message the action never reaches is reported as out of scope, not as protected")
    func doesNotClaimCreditForMessagesItWouldNotHaveTouched() throws {
        // Two starred messages, both among the newest — well inside a 10-day cutoff.
        let messages = dailySender(starredCount: 2)
        let result = plan(
            [CleanupPlanRequest(senderKey: key(messages), action: .archiveMessagesOlderThan(days: 10))],
            senders: [messages]
        )
        let entry = try #require(result.entries.first)

        #expect(entry.protectedMessageCount == 0, "Nothing was saved from an action that never reached it")
        #expect(entry.exclusions.first { $0.reason == .newerThanCutoff(days: 10) }?.messageCount == 10)
    }

    @Test("Keep-newest-N retains exactly N and affects the rest")
    func keepsTheNewestN() throws {
        let messages = dailySender(count: 12)
        let result = plan(
            [CleanupPlanRequest(senderKey: key(messages), action: .keepNewest(count: 5))],
            senders: [messages]
        )
        let entry = try #require(result.entries.first)

        #expect(entry.affectedMessageCount == 7)
        #expect(entry.retainedMessageCount == 5)
        #expect(entry.exclusions == [CleanupExclusion(reason: .amongNewestKept(count: 5), messageCount: 5)])
    }

    @Test("Keep-newest-N keeps more than N when some of the rest are protected")
    func keepNewestStillHonoursProtection() throws {
        var subjects = ProposalFixtures.neutralSubjects(12, prefix: "Weekend sale")
        subjects[9] = "Your receipt"
        let messages = ProposalFixtures.messages(
            from: "deals@example.com",
            subjects: subjects,
            hoursApart: 24,
            labels: [.inbox, .categoryPromotions],
            listUnsubscribe: true
        )
        let result = plan(
            [CleanupPlanRequest(senderKey: key(messages), action: .keepNewest(count: 5))],
            senders: [messages]
        )
        let entry = try #require(result.entries.first)

        #expect(entry.affectedMessageCount == 6)
        #expect(entry.retainedMessageCount == 6)
        #expect(entry.protectedMessageCount == 1)
    }

    @Test("Reviewing a subscription moves nothing and says so")
    func reviewSubscriptionMovesNothing() throws {
        let messages = dailySender()
        let result = plan(
            [CleanupPlanRequest(senderKey: key(messages), action: .reviewSubscription)],
            senders: [messages]
        )
        let entry = try #require(result.entries.first)

        #expect(entry.affectedMessageCount == 0)
        #expect(entry.retainedMessageCount == 20)
        #expect(entry.exclusions == [CleanupExclusion(reason: .actionMovesNoMessages, messageCount: 20)])
    }

    // MARK: - Multiple senders

    @Test("A plan spanning several senders totals them without mixing them up")
    func plansAcrossSenders() {
        let deals = dailySender("deals@example.com", count: 20, idPrefix: "d")
        let list = dailySender("list@example.org", count: 12, idPrefix: "l")

        let result = plan(
            [
                CleanupPlanRequest(senderKey: key(deals), action: .archiveMessagesOlderThan(days: 10)),
                CleanupPlanRequest(senderKey: key(list), action: .keepNewest(count: 5)),
            ],
            senders: [deals, list]
        )

        #expect(result.senderCount == 2)
        #expect(result.entries.map(\.affectedMessageCount) == [10, 7])
        #expect(result.totalAffectedMessageCount == 17)
        #expect(result.totalRetainedMessageCount == 15)
        // Entries keep the order they were requested in, so a preview reads like the list did.
        #expect(result.entries.map(\.sender.address) == ["deals@example.com", "list@example.org"])
    }

    @Test("Selecting the same sender twice cannot double-count its mail")
    func collapsesDuplicateRequests() {
        let messages = dailySender()
        let result = plan(
            [
                CleanupPlanRequest(senderKey: key(messages), action: .archiveMessagesOlderThan(days: 10)),
                CleanupPlanRequest(senderKey: key(messages), action: .keepNewest(count: 1)),
            ],
            senders: [messages]
        )

        #expect(result.senderCount == 1)
        #expect(result.totalAffectedMessageCount == 10, "The first request wins; the second is ignored")
    }

    @Test("An empty selection produces an empty plan rather than an empty-looking one")
    func handlesAnEmptySelection() {
        let result = plan([], senders: [dailySender()])

        #expect(result.isEmpty)
        #expect(result.totalAffectedMessageCount == 0)
        #expect(result.totalRetainedMessageCount == 0)
    }

    @Test("A sender with no loaded messages is skipped rather than previewed as zero")
    func skipsSendersWithNothingLoaded() {
        let result = plan(
            [CleanupPlanRequest(senderKey: "ghost@example.com", action: .keepNewest(count: 5))],
            senders: [dailySender()]
        )

        #expect(result.isEmpty)
    }

    // MARK: - Honesty about the window

    @Test("A partial window says the figures do not describe the whole mailbox")
    func statesTheWindowIsPartial() {
        let messages = dailySender()
        let result = plan(
            [CleanupPlanRequest(senderKey: key(messages), action: .archiveMessagesOlderThan(days: 10))],
            senders: [messages]
        )

        #expect(result.window.isPartial)
        #expect(result.window.explanation.contains("250"))
        #expect(result.window.explanation.contains("never read"))
    }

    @Test("An exhausted window says what it covers without claiming the whole mailbox")
    func statesWhatACompleteWindowCovers() {
        let messages = dailySender()
        let result = plan(
            [CleanupPlanRequest(senderKey: key(messages), action: .archiveMessagesOlderThan(days: 10))],
            senders: [messages],
            window: completeWindow
        )

        #expect(!result.window.isPartial)
        #expect(result.window.explanation.contains("Mail outside the inbox"))
        #expect(!result.window.explanation.contains("whole mailbox"))
    }

    @Test("Planning for a protected sender is allowed, flagged, and still excludes its mail")
    func flagsPlansThatContradictProtection() throws {
        // A sender whose whole loaded history is receipts: protected, and clearly so.
        let messages = ProposalFixtures.messages(
            from: "orders@example.com",
            subjects: ProposalFixtures.neutralSubjects(10, prefix: "Your order").map { "\($0) has shipped" },
            hoursApart: 24
        )
        let result = plan(
            [CleanupPlanRequest(senderKey: key(messages), action: .trashMessagesOlderThan(days: 2))],
            senders: [messages]
        )
        let entry = try #require(result.entries.first)

        #expect(entry.protection.isProtected)
        #expect(entry.affectedMessageCount == 0, "Every message is individually protected too")
        #expect(entry.protectedMessageCount == 8)
        #expect(!entry.contradictsProtection, "Nothing would be affected, so there is nothing to warn about")
    }

    @Test("The plan is deterministic for the same inputs")
    func isDeterministic() {
        let messages = dailySender(starredCount: 2)
        let request = [CleanupPlanRequest(senderKey: key(messages), action: .archiveMessagesOlderThan(days: 6))]

        #expect(plan(request, senders: [messages]) == plan(request, senders: [messages.shuffled()]))
    }
}

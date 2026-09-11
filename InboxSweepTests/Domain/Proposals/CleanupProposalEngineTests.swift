import Foundation
import Testing
@testable import InboxSweep

/// What the proposal engine concludes, and how it explains itself.
///
/// The cases below are shaped senders rather than crafted inputs: each one is the kind of mail
/// the rules exist to recognise, built from metadata a real mailbox would actually carry.
@Suite("Cleanup proposal engine")
struct CleanupProposalEngineTests {

    // MARK: - Patterns

    @Test("A high-volume Promotions sender with no engagement reads as promotional clutter")
    func recognisesPromotionalClutter() {
        let proposal = ProposalFixtures.proposal(for: ProposalFixtures.promotionalSender())

        #expect(proposal.kind == .likelyPromotionalClutter)
        #expect(proposal.strength == .strong)
        #expect(proposal.protection.level == .none)
        // The volume reason names Gmail's category rather than inventing one.
        #expect(proposal.reasons.contains { $0.text == "24 promotional messages from this sender in the loaded window" })
        #expect(proposal.reasons.contains { $0.text == "Gmail files this sender's mail under Promotions" })
    }

    @Test("A weekly list with unsubscribe metadata reads as a newsletter, not as clutter")
    func recognisesNewsletter() {
        let proposal = ProposalFixtures.proposal(for: ProposalFixtures.newsletterSender())

        #expect(proposal.kind == .likelyNewsletter)
        #expect(proposal.reasons.contains { $0.text == "Mailing-list unsubscribe metadata on every loaded message" })
        #expect(proposal.reasons.contains { $0.text == "About 1 message per week" })
        // Gmail never filed this under Promotions, so nothing calls it promotional.
        #expect(!proposal.reasons.contains { $0.text.contains("promotional") })
    }

    @Test("An automated address on a steady cadence reads as a recurring notification")
    func recognisesRecurringNotification() {
        let proposal = ProposalFixtures.proposal(for: ProposalFixtures.notificationSender())

        #expect(proposal.kind == .likelyRecurringNotification)
        #expect(proposal.reasons.contains { $0.text == "Arrives from an automated-looking address" })
        // No `List-Unsubscribe` anywhere, so nothing claims there is a subscription to leave.
        #expect(!proposal.reasons.contains { $0.text.contains("unsubscribe") })
    }

    @Test("Bulk-mail signals that match no pattern become a deliberately vague candidate")
    func fallsBackToACleanupCandidate() {
        // List metadata and volume, but no category, no cadence in range, and no automated
        // address: enough signals to be worth raising, not enough to name a pattern.
        let messages = ProposalFixtures.messages(
            from: "hello@example.org",
            subjects: ProposalFixtures.neutralSubjects(30),
            hoursApart: 24 * 90,
            listUnsubscribe: true,
            unreadCount: 30
        )
        let proposal = ProposalFixtures.proposal(for: messages)

        #expect(proposal.kind == .possibleCleanupCandidate)
        #expect(proposal.suggestsCleanup)
    }

    // MARK: - Restraint

    @Test("A sender with too little loaded mail is never proposed for cleanup")
    func withholdsJudgementOnLowVolumeSenders() {
        let proposal = ProposalFixtures.proposal(for: ProposalFixtures.lowVolumeSender())

        #expect(!proposal.suggestsCleanup)
        #expect(proposal.reasons.contains { $0.kind == .insufficientEvidence })
        #expect(proposal.reasons.contains { $0.text.contains("too few") })
    }

    @Test("A single bulk-mail signal is never enough for a cleanup-oriented proposal")
    func requiresCorroboration() {
        // Gmail's Promotions category and nothing else: no volume, no list metadata, no
        // cadence, and not enough messages for an absence to mean anything.
        let messages = ProposalFixtures.messages(
            from: "shop@example.com",
            subjects: ProposalFixtures.neutralSubjects(6),
            hoursApart: 24 * 200,
            labels: [.inbox, .categoryPromotions]
        )
        let proposal = ProposalFixtures.proposal(for: messages)

        #expect(!proposal.suggestsCleanup)
    }

    @Test("Gmail's Personal category stops a cleanup proposal even without a protection signal")
    func respectsThePersonalCategory() {
        let messages = ProposalFixtures.messages(
            from: "colleague@example.net",
            subjects: ProposalFixtures.neutralSubjects(20, prefix: "Notes"),
            hoursApart: 30,
            labels: [.inbox, .categoryPersonal],
            unreadCount: 20
        )
        let proposal = ProposalFixtures.proposal(for: messages)

        #expect(proposal.protection.level == .none, "Nothing here is a protection signal on its own")
        #expect(!proposal.suggestsCleanup)
    }

    // MARK: - Determinism

    @Test("The same messages always produce the same proposal, whatever order they arrive in")
    func isDeterministic() {
        let messages = ProposalFixtures.promotionalSender()
        let forwards = ProposalFixtures.proposal(for: messages)
        let backwards = ProposalFixtures.proposal(for: messages.reversed())
        let shuffled = ProposalFixtures.proposal(for: messages.shuffled())

        #expect(forwards == backwards)
        #expect(forwards == shuffled)
        #expect(forwards.reasons.map(\.text) == shuffled.reasons.map(\.text))
    }

    @Test("Reasons appear in a fixed order, protection always first")
    func ordersReasonsStably() {
        // A protected sender that is also unmistakably bulk mail, so both kinds of reason are
        // present and their relative order is actually under test.
        var messages = ProposalFixtures.promotionalSender(count: 20)
        messages += ProposalFixtures.messages(
            from: "Storefront Deals <deals@example.com>",
            subjects: ["Your order has shipped", "Your order confirmation"],
            labels: [.inbox, .categoryPromotions],
            idPrefix: "order"
        )
        let proposal = ProposalFixtures.proposal(for: messages)

        let kinds = proposal.reasons.map(\.kind)
        #expect(kinds == kinds.sorted(), "Reasons must be emitted in ProposalReason.Kind order")
        #expect(kinds.first == .protection)
        #expect(proposal.reasons.map(\.text) == ProposalFixtures.proposal(for: messages.shuffled()).reasons.map(\.text))
    }

    @Test("Every proposal explains itself")
    func alwaysExplainsItself() {
        let senders = [
            ProposalFixtures.promotionalSender(),
            ProposalFixtures.newsletterSender(),
            ProposalFixtures.notificationSender(),
            ProposalFixtures.lowVolumeSender(),
        ]

        for messages in senders {
            let proposal = ProposalFixtures.proposal(for: messages)
            #expect(!proposal.reasons.isEmpty)
            #expect(proposal.reasons.allSatisfy { !$0.text.isEmpty })
        }
    }

    @Test("A proposal exposes no raw score, only a named strength and sentences")
    func exposesNoInternalScore() {
        let proposal = ProposalFixtures.proposal(for: ProposalFixtures.promotionalSender())
        let propertyNames = Set(Mirror(reflecting: proposal).children.compactMap(\.label))
        let scoringNames: Set<String> = ["score", "cleanupScore", "confidenceValue", "weight", "points", "rating"]

        #expect(propertyNames.isDisjoint(with: scoringNames))
        #expect(proposal.reasons.allSatisfy { !$0.text.contains("score") })
    }

    @Test("Proposals for a whole window are keyed by the same sender key the dashboard uses")
    func evaluatesAWholeWindow() throws {
        let messages = ProposalFixtures.promotionalSender(count: 12) + ProposalFixtures.newsletterSender(count: 12)
        let summaries = SenderAggregator.aggregate(messages)
        let proposals = CleanupProposalEngine.evaluate(summaries: summaries, messages: messages)

        #expect(proposals.count == summaries.count)
        for summary in summaries {
            #expect(try #require(proposals[summary.id]).loadedMessageCount == summary.messageCount)
        }
    }
}

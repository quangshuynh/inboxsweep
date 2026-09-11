import Foundation
import Testing
@testable import InboxSweep

/// The rules that stop InboxSweep suggesting cleanup for mail worth keeping.
///
/// These are the tests that matter most if the heuristics are ever loosened: everything else
/// costs a suggestion, and this costs the user's mail.
@Suite("Sender protection")
struct SenderProtectionTests {

    /// A sender whose subjects are all on one topic, so the topic rule is what is under test
    /// rather than the corroboration threshold.
    private func topicSender(_ subjects: [String], address: String = "sender@example.com") -> SenderEvidence {
        ProposalFixtures.evidence(
            for: ProposalFixtures.messages(from: address, subjects: subjects, hoursApart: 72)
        )
    }

    // MARK: - Each supported signal

    @Test(
        "Each protective subject topic is recognised on its own",
        arguments: [
            (["Security alert: new sign-in", "Verify your account"], SubjectTopic.accountSecurity),
            (["Your monthly statement", "Payment received"], SubjectTopic.financial),
            (["Your order has shipped", "Order confirmation 8812"], SubjectTopic.receiptOrOrder),
            (["Your boarding pass", "Booking confirmation"], SubjectTopic.travel),
            (["Your tax return is ready", "Notice from the IRS"], SubjectTopic.governmentOrTax),
            (["Interview scheduled", "Your application update"], SubjectTopic.employment),
            (["Appointment reminder", "Your lab results"], SubjectTopic.healthcare),
        ]
    )
    func recognisesEachProtectiveTopic(subjects: [String], topic: SubjectTopic) {
        let assessment = SenderProtection.assess(topicSender(subjects))

        #expect(assessment.level == .protected)
        #expect(assessment.signals.contains { $0.kind == .subjectTopic(topic) })
    }

    @Test("A starred message protects a sender on its own")
    func starredMessagesProtect() {
        let messages = ProposalFixtures.messages(
            from: "deals@example.com",
            subjects: ProposalFixtures.neutralSubjects(20),
            labels: [.inbox, .categoryPromotions],
            listUnsubscribe: true,
            starredCount: 1
        )
        let assessment = SenderProtection.assess(ProposalFixtures.evidence(for: messages))

        #expect(assessment.level == .protected)
        #expect(assessment.signals.contains { $0.kind == .starred })
    }

    @Test("A message Gmail marked Important protects a sender on its own")
    func importantMessagesProtect() {
        let messages = ProposalFixtures.messages(
            from: "alerts@example.org",
            subjects: ProposalFixtures.neutralSubjects(20),
            importantCount: 1
        )
        let assessment = SenderProtection.assess(ProposalFixtures.evidence(for: messages))

        #expect(assessment.level == .protected)
        #expect(assessment.signals.contains { $0.kind == .markedImportant })
    }

    @Test("Reply-shaped subjects read as personal correspondence")
    func replyLikeSubjectsProtect() {
        let assessment = SenderProtection.assess(
            topicSender(["Re: dinner on Thursday?", "Fwd: photos", "Quick question"], address: "person@example.net")
        )

        #expect(assessment.level == .protected)
        #expect(assessment.signals.contains { $0.kind == .personalCorrespondence })
    }

    // MARK: - Corroboration

    @Test("A single topic mention among many messages is suggestive, not conclusive")
    func treatsASingleMentionAsUncertain() throws {
        var subjects = ProposalFixtures.neutralSubjects(11)
        subjects[3] = "Your order has shipped"
        let assessment = SenderProtection.assess(topicSender(subjects))

        #expect(assessment.level == .possible)
        let signal = try #require(assessment.signals.first)
        #expect(signal.confidence == .suggestive)
        #expect(signal.explanation.contains("may not be what it looks like"))
    }

    @Test("A sender whose whole loaded history is one protective message is protected")
    func treatsAWholeHistoryAsCorroboration() {
        // One message is thin evidence about a sender in general, but it is *all* of what is
        // known about this one, and what is known says tax notice.
        let assessment = SenderProtection.assess(topicSender(["Your tax return is ready"]))

        #expect(assessment.level == .protected)
    }

    @Test("Several signals are all reported, in a fixed order")
    func reportsEverySignalInOrder() {
        let messages = ProposalFixtures.messages(
            from: "no-reply@example.net",
            subjects: ["Your monthly statement", "Security alert: new sign-in", "Payment received", "Verify your account"],
            hoursApart: 72,
            starredCount: 1,
            importantCount: 2
        )
        let assessment = SenderProtection.assess(ProposalFixtures.evidence(for: messages))

        #expect(assessment.level == .protected)
        let ranks = assessment.signals.map(\.kind.rank)
        #expect(ranks == ranks.sorted())
        #expect(assessment.signals.map(\.kind).contains(.starred))
        #expect(assessment.signals.map(\.kind).contains(.markedImportant))
        #expect(assessment.signals.map(\.kind).contains(.subjectTopic(.accountSecurity)))
        #expect(assessment.signals.map(\.kind).contains(.subjectTopic(.financial)))
    }

    @Test("Nothing protective yields no signals at all rather than a hedge")
    func reportsNoSignalWhenThereIsNone() {
        let assessment = SenderProtection.assess(ProposalFixtures.evidence(for: ProposalFixtures.promotionalSender()))

        #expect(assessment.level == .none)
        #expect(!assessment.hasAnySignal)
    }

    // MARK: - Effect on proposals

    @Test("A corroborated signal downgrades a cleanup proposal to keep")
    func corroboratedProtectionDowngradesToKeep() {
        // The same promotional sender as the engine tests, plus two starred messages.
        var messages = ProposalFixtures.promotionalSender(count: 20)
        messages += ProposalFixtures.messages(
            from: "Storefront Deals <deals@example.com>",
            subjects: ["Saved for later", "Still thinking about it"],
            labels: [.inbox, .categoryPromotions],
            starredCount: 2,
            idPrefix: "starred"
        )
        let proposal = ProposalFixtures.proposal(for: messages)

        #expect(ProposalFixtures.proposal(for: ProposalFixtures.promotionalSender(count: 20)).kind == .likelyPromotionalClutter)
        #expect(!proposal.suggestsCleanup)
        #expect(proposal.isProtected)
        #expect(proposal.reasons.first?.kind == .protection)
    }

    @Test("An uncorroborated signal downgrades a cleanup proposal to review, not to keep")
    func uncertainProtectionDowngradesToReview() {
        var subjects = ProposalFixtures.neutralSubjects(23, prefix: "Weekend sale")
        subjects[7] = "Your order has shipped"
        let messages = ProposalFixtures.messages(
            from: "deals@example.com",
            subjects: subjects,
            hoursApart: 20,
            labels: [.inbox, .categoryPromotions],
            listUnsubscribe: true,
            unreadCount: 23
        )
        let proposal = ProposalFixtures.proposal(for: messages)

        #expect(proposal.protection.level == .possible)
        #expect(proposal.kind == .review)
        #expect(proposal.reasons.contains { $0.text.contains("uncorroborated") })
    }

    @Test("A protected sender that is also unmistakably bulk mail is raised for review, not hidden")
    func protectedBulkSenderIsStillWorthLookingAt() {
        var messages = ProposalFixtures.promotionalSender(count: 24)
        messages += ProposalFixtures.messages(
            from: "Storefront Deals <deals@example.com>",
            subjects: ["Your order has shipped", "Your order confirmation"],
            labels: [.inbox, .categoryPromotions],
            idPrefix: "order"
        )
        let proposal = ProposalFixtures.proposal(for: messages)

        #expect(proposal.isProtected)
        #expect(proposal.kind == .review, "Keep would hide a sender the user probably does want to see")
        #expect(!proposal.suggestsCleanup)
    }

    // MARK: - Message-level protection

    @Test("Message-level protection reports the exact reason a message was held back")
    func explainsMessageLevelProtection() {
        let starred = ProposalFixtures.messages(from: "a@example.com", subjects: ["Anything"], starredCount: 1)[0]
        let important = ProposalFixtures.messages(from: "a@example.com", subjects: ["Anything"], importantCount: 1)[0]
        let receipt = ProposalFixtures.messages(from: "a@example.com", subjects: ["Your order has shipped"])[0]
        let reply = ProposalFixtures.messages(from: "a@example.com", subjects: ["Re: last week"])[0]
        let ordinary = ProposalFixtures.messages(from: "a@example.com", subjects: ["Weekend sale"])[0]

        #expect(SenderProtection.protectionReason(for: starred) == .starred)
        #expect(SenderProtection.protectionReason(for: important) == .markedImportant)
        #expect(SenderProtection.protectionReason(for: receipt) == .protectedTopic(.receiptOrOrder))
        #expect(SenderProtection.protectionReason(for: reply) == .replyLikeSubject)
        #expect(SenderProtection.protectionReason(for: ordinary) == nil)
    }

    @Test("Topic matching lands on whole words, so ordinary mail is not mistaken for a receipt")
    func matchesWholeWordsOnly() {
        #expect(SubjectTopic.topics(in: "Reorder your usual?").isEmpty)
        #expect(SubjectTopic.topics(in: "Crossing borders: a photo essay").isEmpty)
        #expect(SubjectTopic.topics(in: "Your order has shipped") == [.receiptOrOrder])
        // The `%` is spelled out so a discount reads as a discount.
        #expect(SubjectTopic.topics(in: "Extra 20% off today") == [.promotionalOffer])
    }
}

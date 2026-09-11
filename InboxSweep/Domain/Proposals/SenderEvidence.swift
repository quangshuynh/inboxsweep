import Foundation

/// Everything the proposal engine is allowed to reason from about one sender.
///
/// A deliberate narrowing. The engine never sees a ``MailMessage``; it sees this, which is
/// built once from the loaded window and contains only facts the mailbox already stated,
/// counts, dates, labels Gmail applied, headers that were present, and whether certain words
/// appeared in subject lines. Keeping the input in one named type is what makes the rules
/// reviewable: everything a proposal can possibly be based on is listed below.
///
/// Every count here is scoped to the *loaded window*, exactly as ``SenderSummary`` is.
nonisolated struct SenderEvidence: Identifiable, Hashable, Sendable {

    /// The per-sender facts the aggregator already derived.
    let summary: SenderSummary

    /// Subject-line keyword categories seen on this sender's loaded messages, with how many
    /// messages each was seen on.
    ///
    /// A count rather than a flag because "one subject mentioned an invoice" and "eleven did"
    /// are different kinds of evidence, and the protection rules treat them differently.
    let subjectTopicCounts: [SubjectTopic: Int]

    /// How many loaded messages had a reply- or forward-style subject (`Re:`, `Fwd:`).
    ///
    /// The closest thing to a "someone had a conversation here" signal available from
    /// metadata alone. It is not proof of one: automated mail can carry `Re:` too.
    let replyLikeSubjectCount: Int

    /// Whether the address' local part looks machine-operated (`no-reply`, `notifications`…).
    let hasAutomatedSenderLocalPart: Bool

    var id: SenderSummary.ID { summary.id }
    var sender: EmailAddress { summary.sender }

    init(
        summary: SenderSummary,
        subjectTopicCounts: [SubjectTopic: Int] = [:],
        replyLikeSubjectCount: Int = 0,
        hasAutomatedSenderLocalPart: Bool = false
    ) {
        self.summary = summary
        self.subjectTopicCounts = subjectTopicCounts
        self.replyLikeSubjectCount = replyLikeSubjectCount
        self.hasAutomatedSenderLocalPart = hasAutomatedSenderLocalPart
    }

    /// How many loaded messages carried a subject matching `topic`.
    func messageCount(matching topic: SubjectTopic) -> Int {
        subjectTopicCounts[topic] ?? 0
    }

    /// The topics seen at all, in a fixed order so reasoning reads the same way every time.
    var observedTopics: [SubjectTopic] {
        SubjectTopic.allCases.filter { messageCount(matching: $0) > 0 }
    }

    /// The span the loaded messages cover. Zero when only one message was loaded.
    var loadedWindowSpan: TimeInterval {
        max(0, summary.newestReceivedAt.timeIntervalSince(summary.oldestLoadedReceivedAt))
    }
}

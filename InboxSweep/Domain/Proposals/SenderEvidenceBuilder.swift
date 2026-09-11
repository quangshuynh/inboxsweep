import Foundation

/// Turns a loaded window into one ``SenderEvidence`` per sender.
///
/// Pure and deterministic: the same messages in any order produce the same evidence. It is
/// the only place that reads message *subjects* for anything other than display, and it reads
/// them into counts — the engine downstream never sees a subject line.
nonisolated enum SenderEvidenceBuilder {

    /// Local-part fragments that mark an address as machine-operated.
    ///
    /// Compared against the local part with punctuation removed, so `no-reply`, `no_reply`,
    /// and `noreply` are all the same fragment. Deliberately excludes bulk-mail words like
    /// "news" or "deals": that a sender is *automated* is a different claim from that its mail
    /// is promotional, and the promotional claim has better evidence available to it
    /// (Gmail's own category, and a `List-Unsubscribe` header).
    static let automatedLocalPartFragments = [
        "noreply", "donotreply", "notification", "alert", "mailer", "automated",
        "autoreply", "postmaster", "bounce", "daemon",
    ]

    /// Subject prefixes that indicate a reply or forward.
    static let replyLikeSubjectPrefixes = ["re:", "fw:", "fwd:"]

    /// Builds evidence for every summary in `summaries`, using `messages` for the subject and
    /// address signals the summaries do not carry.
    ///
    /// Returned in the same order as `summaries`, so an already-sorted dashboard stays sorted.
    static func build(summaries: [SenderSummary], messages: [MailMessage]) -> [SenderEvidence] {
        var messagesBySender: [SenderSummary.ID: [MailMessage]] = [:]
        messagesBySender.reserveCapacity(summaries.count)
        for message in messages {
            messagesBySender[message.sender.groupingKey, default: []].append(message)
        }

        return summaries.map { build(summary: $0, messages: messagesBySender[$0.id] ?? []) }
    }

    /// Builds evidence for a single sender from its own loaded messages.
    static func build(summary: SenderSummary, messages: [MailMessage]) -> SenderEvidence {
        var topicCounts: [SubjectTopic: Int] = [:]
        var replyLikeCount = 0

        for message in messages {
            guard let subject = message.subject, !subject.isEmpty else { continue }

            for topic in SubjectTopic.topics(in: subject) {
                topicCounts[topic, default: 0] += 1
            }

            if isReplyLike(subject) { replyLikeCount += 1 }
        }

        return SenderEvidence(
            summary: summary,
            subjectTopicCounts: topicCounts,
            replyLikeSubjectCount: replyLikeCount,
            hasAutomatedSenderLocalPart: hasAutomatedLocalPart(summary.sender)
        )
    }

    /// Whether a subject reads as a reply or forward.
    static func isReplyLike(_ subject: String) -> Bool {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return replyLikeSubjectPrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// Whether the address' local part reads as machine-operated.
    ///
    /// Senders with no parseable address are not automated by default: that bucket can hold
    /// several genuinely different senders, and guessing on their behalf would be exactly the
    /// kind of confident-but-wrong claim the protection rules exist to avoid.
    static func hasAutomatedLocalPart(_ sender: EmailAddress) -> Bool {
        guard sender.hasAddress, let localPart = sender.address.split(separator: "@").first else {
            return false
        }
        let compact = localPart.lowercased().filter { $0.isLetter || $0.isNumber }
        return automatedLocalPartFragments.contains { compact.contains($0) }
    }
}

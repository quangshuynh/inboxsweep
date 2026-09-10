import Foundation

/// What the protection rules concluded about one sender.
nonisolated struct SenderProtectionAssessment: Hashable, Sendable {

    /// How strongly the loaded metadata argues for leaving this sender alone.
    nonisolated enum Level: Int, Comparable, Hashable, Sendable {

        /// Nothing in the loaded window suggests this sender needs protecting.
        case none

        /// Something does, but weakly — a single subject line, one reply-shaped message.
        /// Enough to stop InboxSweep proposing cleanup, not enough to say why with confidence.
        case possible

        /// Corroborated. The sender is not proposed for cleanup at all.
        case protected

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let level: Level

    /// Every signal found, ordered by ``ProtectionSignal/Kind/rank``.
    let signals: [ProtectionSignal]

    static let unprotected = SenderProtectionAssessment(level: .none, signals: [])

    var isProtected: Bool { level == .protected }
    var hasAnySignal: Bool { !signals.isEmpty }

    /// The signals that carried the decision, for a UI that only has room for one or two.
    var clearSignals: [ProtectionSignal] { signals.filter { $0.confidence == .clear } }
}

/// Decides whether a sender's loaded mail looks too valuable to propose cleaning up.
///
/// Runs *before* any cleanup rule and can only ever veto one. Its rules are listed in
/// ``SenderProtection/assess(_:)`` and every one of them reads a fact the mailbox already
/// stated: a star the user added, a flag Gmail applied, a word that appeared in a subject
/// line, a subject that begins with `Re:`.
///
/// The rules are conservative on purpose, and their conservatism is asymmetric: a false
/// positive here costs the user a suggestion, while a false negative would put a sender they
/// care about in front of a cleanup plan. Metadata classification is not good enough to be
/// even-handed about that trade.
nonisolated enum SenderProtection {

    /// How many messages must carry a protective topic before it is treated as corroborated.
    ///
    /// A single match among many messages is common and often accidental — one order
    /// confirmation from a shop that otherwise only sends offers. Two is not proof either,
    /// which is why even a corroborated signal produces a *warning*, never a claim.
    static let corroboratingMessageCount = 2

    /// Assesses `evidence` against every protection rule.
    ///
    /// Rules, in the order the signals are reported:
    ///
    /// 1. **Starred** — any starred message. A star is a deliberate act by the user, so one is
    ///    enough and it is never treated as weak.
    /// 2. **Marked Important** — any message Gmail flagged. Gmail's judgement, reported as
    ///    Gmail's, and again enough on its own.
    /// 3. **Personal correspondence** — subjects beginning `Re:` or `Fwd:`. Two or more, or one
    ///    alongside Gmail's Personal category, is corroborated; a single one is suggestive.
    /// 4. **Protective subject topics** — account/security, financial, receipts, travel,
    ///    government/tax, employment, healthcare. Corroborated at
    ///    ``corroboratingMessageCount`` messages, or when every loaded message from the sender
    ///    matches; suggestive at one.
    ///
    /// Any corroborated signal yields ``SenderProtectionAssessment/Level/protected``; only
    /// suggestive ones yield ``SenderProtectionAssessment/Level/possible``.
    static func assess(_ evidence: SenderEvidence) -> SenderProtectionAssessment {
        var signals: [ProtectionSignal] = []
        let summary = evidence.summary

        if summary.starredCount > 0 {
            signals.append(
                ProtectionSignal(kind: .starred, confidence: .clear, messageCount: summary.starredCount)
            )
        }

        if summary.importantCount > 0 {
            signals.append(
                ProtectionSignal(kind: .markedImportant, confidence: .clear, messageCount: summary.importantCount)
            )
        }

        if evidence.replyLikeSubjectCount > 0 {
            let isPersonalCategory = summary.categoryLabels.contains(.categoryPersonal)
            let isCorroborated = evidence.replyLikeSubjectCount >= corroboratingMessageCount || isPersonalCategory
            signals.append(
                ProtectionSignal(
                    kind: .personalCorrespondence,
                    confidence: isCorroborated ? .clear : .suggestive,
                    messageCount: evidence.replyLikeSubjectCount
                )
            )
        }

        for topic in evidence.observedTopics where topic.isProtective {
            let matched = evidence.messageCount(matching: topic)
            // "Every loaded message" counts as corroboration even for a one-message sender:
            // a sender whose entire known history is a tax notice is not a cleanup candidate.
            let isCorroborated = matched >= corroboratingMessageCount || matched == summary.messageCount
            signals.append(
                ProtectionSignal(
                    kind: .subjectTopic(topic),
                    confidence: isCorroborated ? .clear : .suggestive,
                    messageCount: matched
                )
            )
        }

        signals.sort { $0.kind.rank < $1.kind.rank }

        let level: SenderProtectionAssessment.Level =
            if signals.contains(where: { $0.confidence == .clear }) { .protected }
            else if signals.isEmpty { .none }
            else { .possible }

        return SenderProtectionAssessment(level: level, signals: signals)
    }

    /// Whether one specific loaded message is itself protected.
    ///
    /// Used by the dry-run planner, which has to exclude individual messages rather than whole
    /// senders. Message-level protection is necessarily narrower than sender-level: only what
    /// this message itself carries counts, because that is all that can be said about it.
    static func protectionReason(for message: MailMessage) -> CleanupExclusionReason? {
        if message.isStarred { return .starred }
        if message.isImportant { return .markedImportant }
        if let subject = message.subject {
            // Whole-sender topics are already reflected in the proposal; here the question is
            // narrower — does *this* subject line say something worth keeping?
            if let topic = SubjectTopic.topics(in: subject).first(where: \.isProtective) {
                return .protectedTopic(topic)
            }
            if SenderEvidenceBuilder.isReplyLike(subject) { return .replyLikeSubject }
        }
        return nil
    }
}

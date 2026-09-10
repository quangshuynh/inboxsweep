import Foundation

/// A reason to be careful with a sender.
///
/// Protection signals only ever make InboxSweep *less* willing to suggest cleanup. There is
/// no signal here that pushes the other way, which is why the detection rules can afford to
/// be generous: the cost of a false positive is a suggestion the user does not get, and the
/// cost of a false negative is a suggestion about mail they would rather have kept.
nonisolated struct ProtectionSignal: Identifiable, Hashable, Sendable {

    /// What was noticed.
    nonisolated enum Kind: Hashable, Sendable {

        /// At least one loaded message is starred.
        case starred

        /// At least one loaded message is marked Important by the provider.
        case markedImportant

        /// The mail reads like a conversation rather than a broadcast.
        case personalCorrespondence

        /// Subject lines mention a topic worth protecting.
        case subjectTopic(SubjectTopic)

        /// Fixed position in a rendered list of signals.
        ///
        /// Ordering is by rank, never by discovery order, so a sender's warnings read the same
        /// way on every launch.
        var rank: Int {
            switch self {
            case .starred: 0
            case .markedImportant: 1
            case .personalCorrespondence: 2
            case .subjectTopic(let topic): 3 + (SubjectTopic.allCases.firstIndex(of: topic) ?? 0)
            }
        }

        var displayName: String {
            switch self {
            case .starred: "Starred"
            case .markedImportant: "Marked Important"
            case .personalCorrespondence: "Personal correspondence"
            case .subjectTopic(let topic): topic.displayName
            }
        }
    }

    /// How much weight the signal carries.
    ///
    /// The distinction exists because a single matching subject line among forty is a much
    /// weaker claim than the same match on half the window, and the two should not lead to the
    /// same outcome. A ``clear`` signal protects a sender; a ``suggestive`` one downgrades it
    /// to review.
    nonisolated enum Confidence: Hashable, Sendable {
        /// Corroborated — more than one message, or the sender's whole loaded window.
        case clear
        /// A single, uncorroborated hit. Enough to be careful about, not enough to conclude.
        case suggestive
    }

    let kind: Kind
    let confidence: Confidence

    /// How many loaded messages carry this signal.
    let messageCount: Int

    var id: Kind { kind }

    init(kind: Kind, confidence: Confidence, messageCount: Int) {
        self.kind = kind
        self.confidence = confidence
        self.messageCount = messageCount
    }

    var displayName: String { kind.displayName }

    /// One sentence saying what was observed and, when it is weak, that it is weak.
    ///
    /// Written as an observation about the loaded messages rather than a claim about the
    /// sender: "subject lines mention", not "this is a bank".
    var explanation: String {
        let messages = ProposalPhrasing.loadedMessages(messageCount)

        switch kind {
        case .starred:
            return "\(messages) \(ProposalPhrasing.isAre(messageCount)) starred"
        case .markedImportant:
            return "\(messages) \(ProposalPhrasing.isAre(messageCount)) marked Important by Gmail"
        case .personalCorrespondence:
            return "\(messages) \(ProposalPhrasing.looksLook(messageCount)) like part of a conversation "
                + "rather than a broadcast"
        case .subjectTopic(let topic):
            let base = "\(messages) mention \(topic.evidencePhrase) in the subject line"
            return confidence == .suggestive
                ? "\(base) — a single mention, so it may not be what it looks like"
                : base
        }
    }
}

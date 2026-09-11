import Foundation

/// Why a loaded message would not be touched by a planned action.
///
/// Every retained message has exactly one of these, so a preview's retained count is never a
/// residual: it is the sum of stated reasons. "43 would be archived, 7 retained" invites the
/// question "which seven?", and this is the answer.
nonisolated enum CleanupExclusionReason: Hashable, Sendable {

    /// The user starred it.
    case starred

    /// Gmail marked it Important.
    case markedImportant

    /// Its subject line mentions something worth keeping.
    case protectedTopic(SubjectTopic)

    /// Its subject reads as a reply or forward.
    case replyLikeSubject

    /// It is newer than the action's cutoff.
    case newerThanCutoff(days: Int)

    /// It is one of the newest messages the action keeps.
    case amongNewestKept(count: Int)

    /// The action does not move messages at all.
    case actionMovesNoMessages

    /// Whether this message is being held back *for its own sake* rather than because the
    /// action's scope never reached it.
    ///
    /// This is the distinction the preview headlines: "3 protected messages excluded" means
    /// three messages the action would otherwise have taken.
    var isProtective: Bool {
        switch self {
        case .starred, .markedImportant, .protectedTopic, .replyLikeSubject: true
        case .newerThanCutoff, .amongNewestKept, .actionMovesNoMessages: false
        }
    }

    /// Fixed position in a rendered list, so a preview reads the same way every time.
    var rank: Int {
        switch self {
        case .starred: 0
        case .markedImportant: 1
        case .protectedTopic(let topic): 2 + (SubjectTopic.allCases.firstIndex(of: topic) ?? 0)
        case .replyLikeSubject: 20
        case .newerThanCutoff: 30
        case .amongNewestKept: 31
        case .actionMovesNoMessages: 32
        }
    }

    /// The exact reason, phrased for `count` messages.
    func explanation(count: Int) -> String {
        let messages = ProposalPhrasing.messages(count)
        let isAre = ProposalPhrasing.isAre(count)

        switch self {
        case .starred:
            return "\(messages) \(isAre) starred"
        case .markedImportant:
            return "\(messages) \(isAre) marked Important by Gmail"
        case .protectedTopic(let topic):
            return "\(messages) \(ProposalPhrasing.mentionsMention(count)) \(topic.evidencePhrase) in the subject line"
        case .replyLikeSubject:
            return "\(messages) \(ProposalPhrasing.looksLook(count)) like part of a conversation"
        case .newerThanCutoff(let days):
            return "\(messages) arrived within the last \(days) days"
        case .amongNewestKept(let keep):
            return "\(messages) \(isAre) among the newest \(keep) this action keeps"
        case .actionMovesNoMessages:
            return "Reviewing a subscription doesn't move or remove any message"
        }
    }
}

/// One reason, and how many loaded messages it applies to.
nonisolated struct CleanupExclusion: Identifiable, Hashable, Sendable {

    let reason: CleanupExclusionReason
    let messageCount: Int

    var id: CleanupExclusionReason { reason }
    var isProtective: Bool { reason.isProtective }
    var explanation: String { reason.explanation(count: messageCount) }
}

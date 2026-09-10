import Foundation

/// What InboxSweep suggests for a sender.
///
/// The vocabulary is chosen as carefully as the rules are. Nothing here says a sender is
/// junk, spam, useless, or safe to delete — the app is reading metadata from a bounded window
/// of a mailbox, which supports "this reads like a mailing list" and does not support "you do
/// not need this". Every case below is a description of what the mail *looks like*, or an
/// invitation to go and look.
nonisolated enum CleanupProposalKind: String, CaseIterable, Hashable, Sendable, Identifiable {

    /// Leave it alone. Either nothing suggests otherwise, or protection signals say so.
    case keep

    /// Worth the user's eyes. The evidence points somewhere but not far enough.
    case review

    /// Reads like a subscribed mailing list.
    case likelyNewsletter

    /// Reads like marketing mail arriving in volume without much engagement.
    case likelyPromotionalClutter

    /// Reads like automated status mail from a service.
    case likelyRecurringNotification

    /// Several bulk-mail signals line up without matching a more specific pattern.
    case possibleCleanupCandidate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keep: "Keep"
        case .review: "Review"
        case .likelyNewsletter: "Likely newsletter"
        case .likelyPromotionalClutter: "Likely promotional clutter"
        case .likelyRecurringNotification: "Likely recurring notification"
        case .possibleCleanupCandidate: "Possible cleanup candidate"
        }
    }

    /// What the suggestion means, in one sentence, for a UI that has room to say so.
    var explanation: String {
        switch self {
        case .keep:
            "Nothing in the loaded window suggests cleaning this sender up."
        case .review:
            "Something here is worth a look, but the loaded metadata doesn't support a confident suggestion."
        case .likelyNewsletter:
            "Reads like a mailing list you subscribed to. Reviewing the subscription usually helps more than removing individual messages."
        case .likelyPromotionalClutter:
            "Reads like marketing mail: it arrives in volume, Gmail files it under Promotions, and little in the window suggests you engage with it."
        case .likelyRecurringNotification:
            "Reads like automated status mail from a service rather than something written to you."
        case .possibleCleanupCandidate:
            "Several bulk-mail signals line up, without matching one of the more specific patterns."
        }
    }

    /// Whether this suggestion points towards removing mail.
    ///
    /// The protection rules use this to decide what to veto: a proposal that is not
    /// cleanup-oriented has nothing to downgrade.
    var isCleanupOriented: Bool {
        switch self {
        case .keep, .review: false
        case .likelyNewsletter, .likelyPromotionalClutter, .likelyRecurringNotification, .possibleCleanupCandidate: true
        }
    }

    /// An SF Symbol for the badge.
    var symbolName: String {
        switch self {
        case .keep: "lock.shield"
        case .review: "questionmark.circle"
        case .likelyNewsletter: "newspaper"
        case .likelyPromotionalClutter: "tag"
        case .likelyRecurringNotification: "bell.badge"
        case .possibleCleanupCandidate: "tray.full"
        }
    }
}

/// How much the loaded window supports a proposal.
///
/// A named band rather than a number. The engine does count corroborating signals internally,
/// but a "cleanup score: 7" on screen would invite the user to trust an arithmetic they cannot
/// see; a band plus the reasons behind it is the same information stated honestly.
nonisolated enum ProposalStrength: Int, CaseIterable, Comparable, Hashable, Sendable {
    case limited
    case moderate
    case strong

    static func < (lhs: ProposalStrength, rhs: ProposalStrength) -> Bool { lhs.rawValue < rhs.rawValue }

    var displayName: String {
        switch self {
        case .limited: "Limited evidence"
        case .moderate: "Moderate evidence"
        case .strong: "Strong evidence"
        }
    }

    /// A compact form for a table cell.
    var shortDisplayName: String {
        switch self {
        case .limited: "Limited"
        case .moderate: "Moderate"
        case .strong: "Strong"
        }
    }
}

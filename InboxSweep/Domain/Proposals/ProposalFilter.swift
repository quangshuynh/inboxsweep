import Foundation

/// A way of narrowing the dashboard to one kind of proposal.
///
/// Lives in the domain rather than in the view because each case is a statement about the
/// proposal model, and a filter defined in a view would be a seventh place where the app
/// decides what "a newsletter" means.
nonisolated enum ProposalFilter: String, CaseIterable, Hashable, Sendable, Identifiable {

    /// Every sender in the loaded window.
    case all

    /// Everything the rules pointed towards cleaning up, of any pattern.
    case cleanupCandidates

    case newsletters
    case promotions
    case notifications

    /// Senders carrying any protection signal, corroborated or not.
    ///
    /// Deliberately wider than "senders the rules protected": a sender flagged for review on a
    /// single weak signal belongs here too, because this filter answers "what did InboxSweep
    /// decide to be careful about?".
    case protectedSenders

    /// Senders the rules would not commit on.
    case needsReview

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: "All senders"
        case .cleanupCandidates: "Cleanup candidates"
        case .newsletters: "Newsletters"
        case .promotions: "Promotions"
        case .notifications: "Notifications"
        case .protectedSenders: "Protected"
        case .needsReview: "Review"
        }
    }

    var symbolName: String {
        switch self {
        case .all: "tray.2"
        case .cleanupCandidates: "tray.full"
        case .newsletters: "newspaper"
        case .promotions: "tag"
        case .notifications: "bell.badge"
        case .protectedSenders: "lock.shield"
        case .needsReview: "questionmark.circle"
        }
    }

    /// What appears when this filter finds nothing, so an empty list is never just blank.
    var emptyStateDescription: String {
        switch self {
        case .all: "No senders in the loaded window."
        case .cleanupCandidates: "No sender in the loaded window matched a cleanup pattern."
        case .newsletters: "No sender in the loaded window reads as a mailing list."
        case .promotions: "No sender in the loaded window reads as promotional mail."
        case .notifications: "No sender in the loaded window reads as automated notifications."
        case .protectedSenders: "Nothing in the loaded window raised a protection signal."
        case .needsReview: "Nothing in the loaded window was left for you to decide on."
        }
    }

    func matches(_ proposal: SenderCleanupProposal) -> Bool {
        switch self {
        case .all: true
        case .cleanupCandidates: proposal.suggestsCleanup
        case .newsletters: proposal.kind == .likelyNewsletter
        case .promotions: proposal.kind == .likelyPromotionalClutter
        case .notifications: proposal.kind == .likelyRecurringNotification
        case .protectedSenders: proposal.hasProtectionSignals
        case .needsReview: proposal.kind == .review
        }
    }
}

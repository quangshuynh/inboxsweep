import Foundation

/// A cleanup a future version of InboxSweep might be able to carry out.
///
/// **Nothing in this file performs anything.** These cases exist so the dry-run planner can
/// describe what an action *would* touch, using only the message metadata already loaded. The
/// app has no Gmail permission that could execute any of them and no code path that tries.
nonisolated enum PlannedCleanupAction: Hashable, Sendable, Identifiable {

    /// Take messages older than `days` out of the inbox, keeping them in the mailbox.
    case archiveMessagesOlderThan(days: Int)

    /// Move messages older than `days` to Trash.
    case trashMessagesOlderThan(days: Int)

    /// Keep the newest `count` messages from the sender and archive the rest.
    case keepNewest(count: Int)

    /// Look at the subscription itself rather than at individual messages.
    ///
    /// Affects no message by definition. Included because for a mailing list it is usually the
    /// action that actually helps, and leaving it out would push the user towards removing mail
    /// when the useful move is to stop more of it arriving.
    case reviewSubscription

    var id: String {
        switch self {
        case .archiveMessagesOlderThan(let days): "archive-\(days)"
        case .trashMessagesOlderThan(let days): "trash-\(days)"
        case .keepNewest(let count): "keep-newest-\(count)"
        case .reviewSubscription: "review-subscription"
        }
    }

    var displayName: String {
        switch self {
        case .archiveMessagesOlderThan(let days): "Archive messages older than \(days) days"
        case .trashMessagesOlderThan(let days): "Move messages older than \(days) days to Trash"
        case .keepNewest(let count): "Keep only the newest \(count)"
        case .reviewSubscription: "Review the subscription"
        }
    }

    /// A short form for a compact control.
    var shortDisplayName: String {
        switch self {
        case .archiveMessagesOlderThan(let days): "Archive > \(days)d"
        case .trashMessagesOlderThan(let days): "Trash > \(days)d"
        case .keepNewest(let count): "Keep newest \(count)"
        case .reviewSubscription: "Review subscription"
        }
    }

    /// How a preview describes the messages this action would reach.
    ///
    /// Always conditional — "would be", never "will be" — because there is nothing behind it
    /// that could make it happen.
    var previewVerbPhrase: String {
        switch self {
        case .archiveMessagesOlderThan: "would be archived"
        case .trashMessagesOlderThan: "would be moved to Trash"
        case .keepNewest: "would be archived"
        case .reviewSubscription: "would be changed"
        }
    }

    /// Whether the action reaches individual messages at all.
    var movesMessages: Bool { self != .reviewSubscription }

    /// The actions offered in the planner, in the order they are shown.
    ///
    /// Archive leads and Trash sits second to last, because the order of a menu is itself a
    /// recommendation. Both cutoffs are offered because the loaded window's depth decides
    /// which one has anything to say: a 250-message inbox often reaches back only a few weeks,
    /// and a 90-day cutoff over it correctly reports that it would touch nothing.
    static let offered: [PlannedCleanupAction] = [
        .keepNewest(count: 5),
        .archiveMessagesOlderThan(days: 30),
        .archiveMessagesOlderThan(days: 90),
        .trashMessagesOlderThan(days: 90),
        .reviewSubscription,
    ]
}

nonisolated extension CleanupProposalKind {

    /// The action a preview starts on for this kind of proposal.
    ///
    /// A mailing list starts on *review the subscription*, because unsubscribing is the move
    /// that actually helps with one; everything else starts on *keep the newest five*, and
    /// nothing starts on Trash.
    ///
    /// Keep-newest rather than an age cutoff because a cutoff's answer depends on how deep the
    /// loaded window happens to be — over a window reaching back three weeks, "older than 90
    /// days" correctly reports that it would touch nothing, which is true and tells the user
    /// nothing. Keep-newest is answerable from any window, and it is still an archive.
    var defaultPlannedAction: PlannedCleanupAction {
        switch self {
        case .likelyNewsletter: .reviewSubscription
        case .likelyPromotionalClutter, .likelyRecurringNotification, .possibleCleanupCandidate:
            .keepNewest(count: 5)
        case .keep, .review: .reviewSubscription
        }
    }
}

import Foundation

/// What a planned action would do to one specific loaded message.
///
/// The counts on a ``CleanupPlanEntry`` answer "how many?". This answers "which ones, and why?",
/// which is the question a user actually has to be able to check before trusting a suggestion.
/// "43 would be archived" is not something anyone can verify, and "these 43, and these 7 were
/// held back because they are starred" is.
///
/// Both are computed by the same pass over the same messages, so a review can never disagree
/// with the totals shown beside it.
nonisolated enum MessagePlanMembership: Hashable, Sendable {

    /// The action's scope reaches this message and nothing holds it back.
    case affected

    /// The message stays put, for exactly this reason.
    case retained(CleanupExclusionReason)

    /// Whether the action would reach this message.
    var isAffected: Bool { self == .affected }

    /// Whether this message is held back *for its own sake* rather than because the action's
    /// scope never reached it.
    var isProtected: Bool {
        if case .retained(let reason) = self { return reason.isProtective }
        return false
    }

    var reason: CleanupExclusionReason? {
        if case .retained(let reason) = self { return reason }
        return nil
    }

    /// A short phrase for a table cell, always conditional.
    func shortDescription(for action: PlannedCleanupAction) -> String {
        switch self {
        case .affected:
            return action.movesMessages ? "Would be affected" : "Unaffected"
        case .retained(let reason):
            return reason.isProtective ? "Held back" : "Out of scope"
        }
    }

    /// The full sentence, phrased for one message.
    func explanation(for action: PlannedCleanupAction) -> String {
        switch self {
        case .affected:
            return "This message \(action.previewVerbPhrase)."
        case .retained(let reason):
            return reason.explanation(count: 1)
        }
    }
}

/// One loaded message as the review screen presents it.
///
/// Carries the message plus the two verdicts about it: whether it is protected on its own
/// merits, and what a *selected* plan would do with it. The second is optional because the
/// review is worth reading with no plan chosen at all, "which messages are these?" is a
/// reasonable question that has nothing to do with cleanup.
///
/// Still metadata only. ``MailMessage`` has nowhere to put a body, so a review screen cannot
/// show message content even by mistake.
nonisolated struct ReviewedMessage: Identifiable, Hashable, Sendable {

    let message: MailMessage

    /// Why this message would be protected from any action that reached it, or `nil`.
    ///
    /// Independent of the selected plan: a starred message is protected whether or not the
    /// chosen action would have touched it.
    let protectionReason: CleanupExclusionReason?

    /// What the selected plan would do with it, or `nil` when no plan is selected.
    let membership: MessagePlanMembership?

    var id: MailMessageID { message.id }

    init(
        message: MailMessage,
        protectionReason: CleanupExclusionReason?,
        membership: MessagePlanMembership? = nil
    ) {
        self.message = message
        self.protectionReason = protectionReason
        self.membership = membership
    }

    var isProtected: Bool { protectionReason != nil }

    /// Whether the selected plan would reach this message.
    var isAffectedByPlan: Bool { membership?.isAffected == true }

    /// The provider's own categories on this message, in the app's fixed display order.
    var categoryLabels: [MailLabel] {
        MailLabel.allCategories.filter(message.labels.contains)
    }

    /// The states worth showing beside the subject, in a fixed order.
    var stateLabels: [String] {
        var states: [String] = []
        if message.isUnread { states.append("Unread") }
        if message.isStarred { states.append("Starred") }
        if message.isImportant { states.append("Important") }
        return states + categoryLabels.map(\.displayName)
    }
}

/// How the message review is ordered.
///
/// Newest and oldest lead because the actions worth previewing are all about age: "keep the
/// newest five" and "archive anything older than ninety days" are both questions about where a
/// message sits in this ordering, and seeing the list in it makes the answer checkable.
nonisolated enum MessageReviewSortOrder: String, CaseIterable, Hashable, Sendable, Identifiable {

    case newestFirst
    case oldestFirst
    case unreadFirst
    case subject

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newestFirst: "Newest first"
        case .oldestFirst: "Oldest first"
        case .unreadFirst: "Unread first"
        case .subject: "Subject"
        }
    }

    /// Sorts `messages` into this order.
    ///
    /// Every comparison ends in the message identifier, so the order is total and a list never
    /// reshuffles between two identical loads: the same property the sender list has.
    func sort(_ messages: [ReviewedMessage]) -> [ReviewedMessage] {
        messages.sorted { lhs, rhs in
            switch self {
            case .newestFirst:
                if lhs.message.receivedAt != rhs.message.receivedAt {
                    return lhs.message.receivedAt > rhs.message.receivedAt
                }
            case .oldestFirst:
                if lhs.message.receivedAt != rhs.message.receivedAt {
                    return lhs.message.receivedAt < rhs.message.receivedAt
                }
            case .unreadFirst:
                if lhs.message.isUnread != rhs.message.isUnread {
                    return lhs.message.isUnread
                }
                if lhs.message.receivedAt != rhs.message.receivedAt {
                    return lhs.message.receivedAt > rhs.message.receivedAt
                }
            case .subject:
                let left = lhs.message.subject ?? ""
                let right = rhs.message.subject ?? ""
                if left.caseInsensitiveCompare(right) != .orderedSame {
                    return left.caseInsensitiveCompare(right) == .orderedAscending
                }
            }
            return lhs.message.id.rawValue < rhs.message.id.rawValue
        }
    }
}

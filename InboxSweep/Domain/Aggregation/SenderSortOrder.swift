import Foundation

/// How the sender dashboard is ordered.
///
/// Every order is a *total* order: each case below lists explicit tie-breakers ending in the
/// sender's grouping key, which is unique per summary. That matters because the dashboard is
/// how a user decides what to look at, and a list that reshuffles between identical loads
/// would quietly undermine trust in everything else the app says.
nonisolated enum SenderSortOrder: String, CaseIterable, Sendable, Identifiable {

    /// Most messages first, then most recent, then grouping key. The dashboard default:
    /// volume is the clearest first answer to "what is filling my inbox?".
    case messageVolume

    /// Most unread first, then total messages, then most recent, then grouping key.
    case unreadVolume

    /// Most recent message first, then total messages, then grouping key.
    case mostRecent

    /// Alphabetical by display value (case- and diacritic-insensitive), then grouping key.
    case senderName

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .messageVolume: "Messages"
        case .unreadVolume: "Unread"
        case .mostRecent: "Most recent"
        case .senderName: "Sender"
        }
    }

    /// The comparison used to sort two summaries. Returns `true` when `lhs` sorts first.
    func areInIncreasingOrder(_ lhs: SenderSummary, _ rhs: SenderSummary) -> Bool {
        switch self {
        case .messageVolume:
            if lhs.messageCount != rhs.messageCount { return lhs.messageCount > rhs.messageCount }
            if lhs.newestReceivedAt != rhs.newestReceivedAt { return lhs.newestReceivedAt > rhs.newestReceivedAt }

        case .unreadVolume:
            if lhs.unreadCount != rhs.unreadCount { return lhs.unreadCount > rhs.unreadCount }
            if lhs.messageCount != rhs.messageCount { return lhs.messageCount > rhs.messageCount }
            if lhs.newestReceivedAt != rhs.newestReceivedAt { return lhs.newestReceivedAt > rhs.newestReceivedAt }

        case .mostRecent:
            if lhs.newestReceivedAt != rhs.newestReceivedAt { return lhs.newestReceivedAt > rhs.newestReceivedAt }
            if lhs.messageCount != rhs.messageCount { return lhs.messageCount > rhs.messageCount }

        case .senderName:
            let comparison = lhs.sender.displayValue.compare(
                rhs.sender.displayValue,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
            if comparison != .orderedSame { return comparison == .orderedAscending }
        }

        // Final tie-breaker: grouping keys are unique per summary, so ordering is total.
        return lhs.sender.groupingKey < rhs.sender.groupingKey
    }
}

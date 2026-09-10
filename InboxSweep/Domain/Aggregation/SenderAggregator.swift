import Foundation

/// Groups loaded messages by sender and derives per-sender counts.
///
/// Pure, synchronous, and deterministic: the same messages in any input order always produce
/// the same summaries in the same output order. That property is what lets the dashboard be
/// re-sorted or recomputed after a new page loads without the list appearing to shuffle on
/// its own.
nonisolated enum SenderAggregator {

    /// How many recent subjects each summary carries.
    static let defaultRecentSubjectLimit = 3

    /// Aggregates `messages` into one summary per normalized sender address.
    ///
    /// Messages whose `From` header could not be parsed all group into a single "unknown
    /// sender" summary rather than fragmenting into one entry per malformed header.
    ///
    /// - Parameters:
    ///   - messages: The loaded message window. Order is irrelevant to the result.
    ///   - sortOrder: The order to return summaries in.
    ///   - recentSubjectLimit: Maximum subjects retained per sender, newest first.
    static func aggregate(
        _ messages: [MailMessage],
        sortedBy sortOrder: SenderSortOrder = .messageVolume,
        recentSubjectLimit: Int = defaultRecentSubjectLimit
    ) -> [SenderSummary] {
        var accumulators: [String: Accumulator] = [:]
        accumulators.reserveCapacity(messages.count)

        for message in messages {
            let key = message.sender.groupingKey
            accumulators[key, default: Accumulator(sender: message.sender)].add(message)
        }

        let summaries = accumulators.values.map { $0.makeSummary(recentSubjectLimit: recentSubjectLimit) }
        return sort(summaries, by: sortOrder)
    }

    /// Re-orders existing summaries without recomputing them.
    static func sort(_ summaries: [SenderSummary], by sortOrder: SenderSortOrder) -> [SenderSummary] {
        summaries.sorted(by: sortOrder.areInIncreasingOrder)
    }

    /// Mutable per-sender state, collapsed into a ``SenderSummary`` once all messages are seen.
    private struct Accumulator {
        private(set) var sender: EmailAddress
        private var messageCount = 0
        private var unreadCount = 0
        private var starredCount = 0
        private var importantCount = 0
        private var newestReceivedAt = Date.distantPast
        private var oldestReceivedAt = Date.distantFuture
        private var categoryLabels: Set<MailLabel> = []
        private var listUnsubscribeCount = 0

        // Cadence is measured only over messages that carried a usable date. A message the
        // normalizer could not date lands on `.distantPast`, and letting one of those into the
        // span would report a sender as writing once every few thousand years.
        private var datedCount = 0
        private var newestDatedAt = Date.distantPast
        private var oldestDatedAt = Date.distantFuture

        /// Kept newest-first and bounded, so aggregation stays O(messages) in memory.
        private var recentSubjects: [(date: Date, id: String, subject: String)] = []

        /// The date and ID of the newest message that supplied a display name, used to pick
        /// one deterministically when a sender's name varies between messages.
        private var displayNameSource: (date: Date, id: String)?

        init(sender: EmailAddress) {
            self.sender = EmailAddress(displayName: nil, address: sender.address)
        }

        mutating func add(_ message: MailMessage) {
            messageCount += 1
            if message.isUnread { unreadCount += 1 }
            if message.isStarred { starredCount += 1 }
            if message.isImportant { importantCount += 1 }
            newestReceivedAt = max(newestReceivedAt, message.receivedAt)
            oldestReceivedAt = min(oldestReceivedAt, message.receivedAt)

            if message.hasListUnsubscribeHeader { listUnsubscribeCount += 1 }
            categoryLabels.formUnion(message.labels.filter(\.isCategory))

            if message.receivedAt > .distantPast {
                datedCount += 1
                newestDatedAt = max(newestDatedAt, message.receivedAt)
                oldestDatedAt = min(oldestDatedAt, message.receivedAt)
            }

            adoptDisplayNameIfNewer(from: message)

            if let subject = message.subject, !subject.isEmpty {
                recentSubjects.append((message.receivedAt, message.id.rawValue, subject))
            }
        }

        /// A sender can present different display names over time. Take the name from the
        /// newest message that has one, breaking date ties on message ID so the choice does
        /// not depend on the order messages arrived in.
        private mutating func adoptDisplayNameIfNewer(from message: MailMessage) {
            // The unknown bucket can hold several genuinely different senders, so borrowing
            // one of their display names for the whole group would misrepresent it.
            guard sender.hasAddress, let name = message.sender.displayName else { return }
            let candidate = (date: message.receivedAt, id: message.id.rawValue)

            if let current = displayNameSource {
                let isNewer = candidate.date > current.date
                    || (candidate.date == current.date && candidate.id < current.id)
                guard isNewer else { return }
            }

            displayNameSource = candidate
            sender = EmailAddress(displayName: name, address: sender.address)
        }

        func makeSummary(recentSubjectLimit: Int) -> SenderSummary {
            let subjects = recentSubjects
                .sorted { lhs, rhs in
                    lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date > rhs.date
                }
                .prefix(recentSubjectLimit)
                .map(\.subject)

            return SenderSummary(
                sender: sender,
                messageCount: messageCount,
                unreadCount: unreadCount,
                starredCount: starredCount,
                importantCount: importantCount,
                newestReceivedAt: newestReceivedAt,
                oldestLoadedReceivedAt: oldestReceivedAt,
                recentSubjects: subjects,
                categoryLabels: categoryLabels,
                listUnsubscribeCount: listUnsubscribeCount,
                averageIntervalBetweenLoadedMessages: averageInterval
            )
        }

        /// The mean gap between consecutive dated messages, or `nil` when there is no gap to
        /// measure — one message, or several that all arrived at the same instant.
        private var averageInterval: TimeInterval? {
            guard datedCount > 1 else { return nil }
            let span = newestDatedAt.timeIntervalSince(oldestDatedAt)
            guard span > 0 else { return nil }
            return span / Double(datedCount - 1)
        }
    }
}

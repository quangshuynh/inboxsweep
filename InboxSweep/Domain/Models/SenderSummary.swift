import Foundation

/// Aggregated, read-only facts about one sender across the messages loaded so far.
///
/// Every count and date in this type is scoped to the *loaded window*: the messages the app
/// has actually fetched, not to the whole mailbox. The naming reflects that, because a
/// summary that quietly implied full-mailbox totals would mislead the user at exactly the
/// moment they are deciding what to do about a sender.
///
/// Notably absent: any judgement. Every field below is something the mailbox already said,
/// a count, a date, a header that was present, a label the provider had already applied, and
/// nothing here combines them into a score or a recommendation. That separation is deliberate:
/// ``SenderCleanupProposal`` is where the app draws conclusions, and keeping it a distinct
/// type means the facts on the dashboard can always be read without the verdict beside them.
nonisolated struct SenderSummary: Identifiable, Hashable, Sendable {

    /// The sender these messages came from.
    let sender: EmailAddress

    /// Number of loaded messages from this sender.
    let messageCount: Int

    /// How many of those are unread.
    let unreadCount: Int

    /// How many of those are starred.
    let starredCount: Int

    /// How many of those the provider marked important.
    let importantCount: Int

    /// Newest received date among the loaded messages.
    let newestReceivedAt: Date

    /// Oldest received date among the loaded messages. This is a floor on how far back the
    /// app has looked, not the date of the sender's first-ever message.
    let oldestLoadedReceivedAt: Date

    /// A few recent subjects, newest first, for recognising the sender at a glance.
    let recentSubjects: [String]

    /// The provider's own inbox categories seen on this sender's loaded messages.
    ///
    /// Gmail applies these itself; InboxSweep only reports which ones turned up. A sender can
    /// appear in more than one, which is why this is a set rather than a single value, and
    /// why it is not called a "category": the app is not assigning one.
    let categoryLabels: Set<MailLabel>

    /// How many of the loaded messages carried a `List-Unsubscribe` header.
    ///
    /// An observation about the mail, not an offer to act on it. InboxSweep has no
    /// unsubscribe feature and never contacts an unsubscribe address.
    let listUnsubscribeCount: Int

    /// Mean time between consecutive loaded messages from this sender.
    ///
    /// `nil` when fewer than two of the loaded messages carry a usable date, because a cadence
    /// needs at least one interval to measure. Computed across the loaded window only, so it
    /// describes how often this sender appeared *in what was fetched*: extending the window
    /// can change it.
    let averageIntervalBetweenLoadedMessages: TimeInterval?

    init(
        sender: EmailAddress,
        messageCount: Int,
        unreadCount: Int,
        starredCount: Int,
        importantCount: Int,
        newestReceivedAt: Date,
        oldestLoadedReceivedAt: Date,
        recentSubjects: [String],
        categoryLabels: Set<MailLabel> = [],
        listUnsubscribeCount: Int = 0,
        averageIntervalBetweenLoadedMessages: TimeInterval? = nil
    ) {
        self.sender = sender
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.starredCount = starredCount
        self.importantCount = importantCount
        self.newestReceivedAt = newestReceivedAt
        self.oldestLoadedReceivedAt = oldestLoadedReceivedAt
        self.recentSubjects = recentSubjects
        self.categoryLabels = categoryLabels
        self.listUnsubscribeCount = listUnsubscribeCount
        self.averageIntervalBetweenLoadedMessages = averageIntervalBetweenLoadedMessages
    }

    /// Stable across reloads, because it is derived from the normalized address.
    var id: String { sender.groupingKey }

    /// Whether every loaded message from this sender is still unread.
    var isEntirelyUnread: Bool { messageCount > 0 && unreadCount == messageCount }

    /// Whether any loaded message from this sender carried a `List-Unsubscribe` header.
    var hasListUnsubscribeHeader: Bool { listUnsubscribeCount > 0 }

    /// The provider's categories in a stable display order, with unmodelled ones last.
    ///
    /// Ordered so a sender's categories read identically between launches; a `Set`'s own
    /// iteration order would not.
    var orderedCategoryLabels: [MailLabel] {
        MailLabel.allCategories.filter(categoryLabels.contains)
            + categoryLabels.filter { !MailLabel.allCategories.contains($0) }
                .sorted { $0.displayName < $1.displayName }
    }
}

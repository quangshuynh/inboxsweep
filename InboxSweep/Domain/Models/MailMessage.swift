import Foundation

/// A provider-assigned message identifier, kept opaque above the provider boundary.
nonisolated struct MailMessageID: Hashable, Sendable, Codable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A provider-assigned thread identifier.
nonisolated struct MailThreadID: Hashable, Sendable, Codable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// The metadata InboxSweep keeps about a single message.
///
/// This is deliberately *metadata only*. Message bodies are never requested from the
/// provider and there is no field to put one in, which keeps the smallest possible amount of
/// mailbox content in memory and makes the read-only posture structural rather than a
/// convention someone has to remember.
nonisolated struct MailMessage: Identifiable, Hashable, Sendable {

    /// Stable provider message identifier.
    let id: MailMessageID

    /// The conversation this message belongs to, when the provider exposes one.
    let threadID: MailThreadID?

    /// The normalized sender.
    let sender: EmailAddress

    /// The decoded subject line, or `nil` when the message has none.
    let subject: String?

    /// When the provider received the message.
    let receivedAt: Date

    /// Provider-neutral labels and categories.
    let labels: Set<MailLabel>

    /// Whether the message carried a `List-Unsubscribe` header.
    ///
    /// Recorded as an observation only. Interval 1 performs no unsubscribe action of any
    /// kind, and nothing in the app reads this flag to decide anything about a sender.
    let hasListUnsubscribeHeader: Bool

    init(
        id: MailMessageID,
        threadID: MailThreadID? = nil,
        sender: EmailAddress,
        subject: String? = nil,
        receivedAt: Date,
        labels: Set<MailLabel> = [],
        hasListUnsubscribeHeader: Bool = false
    ) {
        self.id = id
        self.threadID = threadID
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
        self.labels = labels
        self.hasListUnsubscribeHeader = hasListUnsubscribeHeader
    }

    // Read state lives in `labels` so there is exactly one source of truth; these are
    // conveniences over it rather than independently-settable fields that could disagree.

    var isUnread: Bool { labels.contains(.unread) }
    var isStarred: Bool { labels.contains(.starred) }
    var isImportant: Bool { labels.contains(.important) }
}

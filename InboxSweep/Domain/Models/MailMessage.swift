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

    /// What this message's unsubscribe headers turned out to be.
    ///
    /// Used to be a `Bool` meaning "a `List-Unsubscribe` header was present". That was the
    /// right shape for as long as noticing the header was the whole of what the app did with
    /// it. It is the wrong shape now: a user can be shown a destination and asked to confirm
    /// contacting it, and "a header existed" cannot support that while "this exact HTTPS URL,
    /// declared one-click by this exact second header" can.
    ///
    /// Still metadata, and still parsed at the provider boundary — ``ListUnsubscribeParser``
    /// turns the sender's text into typed values there, so the raw header never travels through
    /// the app as a string something could later hand to a URL loader.
    let unsubscribe: MessageUnsubscribeMetadata

    /// - Parameters:
    ///   - hasListUnsubscribeHeader: The older, coarser form: a header was present and its
    ///     values were not recorded. Kept because the synthetic mailbox, the fixtures, and a
    ///     cache file written before this interval all mean exactly that, and because saying so
    ///     honestly puts a sender in the *ambiguous* state rather than in either "nothing here"
    ///     or a mechanism nobody parsed. Ignored when `unsubscribe` is given.
    init(
        id: MailMessageID,
        threadID: MailThreadID? = nil,
        sender: EmailAddress,
        subject: String? = nil,
        receivedAt: Date,
        labels: Set<MailLabel> = [],
        hasListUnsubscribeHeader: Bool = false,
        unsubscribe: MessageUnsubscribeMetadata? = nil
    ) {
        self.id = id
        self.threadID = threadID
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
        self.labels = labels
        self.unsubscribe = unsubscribe
            ?? (hasListUnsubscribeHeader ? .headerPresentUnparsed : .absent)
    }

    // Read state lives in `labels` so there is exactly one source of truth; these are
    // conveniences over it rather than independently-settable fields that could disagree.

    /// Whether the message carried a `List-Unsubscribe` header at all.
    ///
    /// The observation the dashboard has shown since Interval 2, now derived from the parsed
    /// metadata rather than stored beside it, so the count on the sender inspector and the
    /// mechanism on the unsubscribe review can never disagree about whether a header was there.
    var hasListUnsubscribeHeader: Bool { unsubscribe.hasListUnsubscribeHeader }

    var isUnread: Bool { labels.contains(.unread) }
    var isStarred: Bool { labels.contains(.starred) }
    var isImportant: Bool { labels.contains(.important) }
}

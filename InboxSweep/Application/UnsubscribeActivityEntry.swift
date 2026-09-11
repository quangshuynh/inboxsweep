import Foundation

/// One past unsubscribe, as the Activity screen needs to say it.
///
/// A view over ``UnsubscribeActionRecord``, exactly as ``ActivityEntry`` is a view over a
/// transaction: nothing here is persisted, nothing here is a new fact, and every sentence comes
/// from a field the record already holds.
///
/// ### What it is allowed to say
///
/// Only what InboxSweep did. "Unsubscribe request sent", "Opened unsubscribe page", "Opened
/// email unsubscribe request", three sentences about three things the app performed. There is
/// no wording in here for "you are unsubscribed", "you'll stop hearing from them", or any
/// counting of subscriptions ended, because none of those is something a local record of a sent
/// request can know. Whether a sender honours an unsubscribe is visible only in mail that has
/// not arrived yet.
nonisolated struct UnsubscribeActivityEntry: Identifiable, Hashable, Sendable {

    let record: UnsubscribeActionRecord

    /// The sender, when the loaded window can still name it.
    ///
    /// Resolved from the mailbox cache through the record's source message, exactly as archive
    /// history resolves its messages, so the address is not copied into a second file for the
    /// sake of a better-reading row. Absent is ordinary, not a fault: an unsubscribe from two
    /// months ago names a message no longer in a 250-message window.
    let resolvedSender: EmailAddress?

    var id: UUID { record.id }

    init(record: UnsubscribeActionRecord, resolvedSender: EmailAddress? = nil) {
        self.record = record
        self.resolvedSender = resolvedSender
    }

    // MARK: - Facts

    var occurredAt: Date { record.occurredAt }
    var mechanism: UnsubscribeMechanism.Kind { record.mechanism }
    var outcome: UnsubscribeOutcome.Kind { record.outcome }
    var destinationHost: String { record.destinationHost }
    var statusCode: Int? { record.statusCode }

    /// Whether anything actually left this Mac.
    var reachedSomebody: Bool { record.reachedSomebody }

    // MARK: - Wording

    /// The headline. Read the successful three together: each names an action, not a result.
    var title: String {
        switch outcome {
        case .requestAccepted, .requestSent: "Unsubscribe request sent"
        case .browserOpened: "Opened unsubscribe page"
        case .mailClientOpened: "Opened email unsubscribe request"
        case .requestFailed: "Unsubscribe request failed"
        case .handoffFailed: "Couldn't open unsubscribe"
        case .unsupportedMechanism: "Unsubscribe not attempted"
        case .invalidMetadata: "Unsubscribe not attempted"
        }
    }

    /// The sender, when it can be named, and nothing when it cannot.
    ///
    /// Falls back to the destination host rather than to a placeholder, because the host is a
    /// fact the record itself holds and is the more useful of the two for recognising which
    /// unsubscribe this was.
    var subtitle: String {
        if let resolvedSender, resolvedSender.hasAddress || resolvedSender.displayName != nil {
            return "\(resolvedSender.displayValue) · \(destinationHost)"
        }
        return destinationHost
    }

    /// The state line, or `nil` when the headline already said everything.
    var statusSummary: String? {
        switch outcome {
        case .requestAccepted:
            return statusCode.map { "Accepted by \(destinationHost) (HTTP \($0))" }
                ?? "Accepted by \(destinationHost)"
        case .requestSent:
            return "Delivered to \(destinationHost); the answer didn't confirm anything"
        case .browserOpened, .mailClientOpened:
            return "Finished by you, outside InboxSweep"
        case .requestFailed:
            return statusCode.map { "\(destinationHost) answered HTTP \($0)" } ?? "Nothing reached \(destinationHost)"
        case .handoffFailed:
            return "Nothing was opened"
        case .unsupportedMechanism, .invalidMetadata:
            return "Nothing was sent"
        }
    }

    /// What this row means, in full, for the detail pane.
    ///
    /// Every branch ends by saying what the app cannot know. That is not hedging: the whole
    /// difference between this feature and a dishonest one is whether the app claims a result it
    /// has no way to observe.
    var explanation: String {
        let base: String
        switch outcome {
        case .requestAccepted:
            base = """
                InboxSweep sent one standard one-click unsubscribe request to \(destinationHost), and \
                \(destinationHost) accepted it.
                """
        case .requestSent:
            base = """
                InboxSweep sent one standard one-click unsubscribe request to \(destinationHost). It \
                was delivered; the answer was a redirect, which doesn't say what became of it.
                """
        case .requestFailed:
            base = """
                InboxSweep tried to send a one-click unsubscribe request to \(destinationHost) and it \
                didn't go through. Nothing else was tried: InboxSweep doesn't retry unsubscribe \
                requests on its own.
                """
        case .browserOpened:
            base = """
                InboxSweep opened \(destinationHost) in your browser. It didn't read the page, fill \
                anything in, or submit anything; whatever happened next was yours.
                """
        case .mailClientOpened:
            base = """
                InboxSweep opened a message to \(destinationHost) in your mail app, addressed and \
                unsent. InboxSweep cannot send mail and did not send this.
                """
        case .handoffFailed:
            base = "InboxSweep tried to open an unsubscribe link at \(destinationHost) and nothing opened."
        case .unsupportedMechanism, .invalidMetadata:
            base = "InboxSweep didn't act on this sender's unsubscribe details. Nothing was sent."
        }

        guard reachedSomebody else { return base + " " + Self.noMailChangedNote }
        return base + " " + Self.cannotConfirmNote + " " + Self.noMailChangedNote
    }

    /// The caveat that goes with every action that reached somebody.
    static let cannotConfirmNote = """
        Whether the sender acted on it is not something InboxSweep can see: only the mail that \
        arrives from now on will show that.
        """

    /// The other half: this changed nothing in the mailbox.
    static let noMailChangedNote = """
        No message in your mailbox was changed by this.
        """

    /// Why there is no Undo on this row.
    ///
    /// Said rather than left to an absence, because a user who has just seen Undo beside an
    /// archive row is entitled to know why there isn't one here, and because the honest answer
    /// is interesting: there is no such thing to offer.
    static let noUndoNote = """
        There's no undo for this. Unsubscribing has no standard reverse; nothing an app can send \
        to put you back on a list, so InboxSweep doesn't offer one it couldn't honour. If you want \
        this sender's mail again, sign up with them as you did the first time.
        """

    var symbolName: String {
        switch outcome {
        case .requestAccepted: "checkmark.circle"
        case .requestSent: "paperplane"
        case .browserOpened: "safari"
        case .mailClientOpened: "envelope"
        case .requestFailed, .handoffFailed: "exclamationmark.triangle"
        case .unsupportedMechanism, .invalidMetadata: "minus.circle"
        }
    }
}

/// One row of the Activity screen, of whichever kind.
///
/// An enum rather than a protocol both entry types conform to. A protocol would have needed a
/// lowest common denominator (a title, a date, maybe an `isUndoable`) and the moment
/// `isUndoable` exists on the shared surface, an unsubscribe row has to answer it, and a screen
/// can ask an unsubscribe for an undo. The enum makes the screen switch, which is what it
/// should be doing: the two rows genuinely say different things and offer different controls.
nonisolated enum ActivityTimelineEntry: Identifiable, Hashable, Sendable {

    case archive(ActivityEntry)
    case unsubscribe(UnsubscribeActivityEntry)

    var id: UUID {
        switch self {
        case .archive(let entry): entry.id
        case .unsubscribe(let entry): entry.id
        }
    }

    var occurredAt: Date {
        switch self {
        case .archive(let entry): entry.occurredAt
        case .unsubscribe(let entry): entry.occurredAt
        }
    }

    var title: String {
        switch self {
        case .archive(let entry): entry.title
        case .unsubscribe(let entry): entry.title
        }
    }

    /// The archive entry, for the code paths that are only about those.
    var archiveEntry: ActivityEntry? {
        if case .archive(let entry) = self { return entry }
        return nil
    }

    var unsubscribeEntry: UnsubscribeActivityEntry? {
        if case .unsubscribe(let entry) = self { return entry }
        return nil
    }

    /// One interleaved history, newest first.
    ///
    /// Sorted here rather than in the store, because the two kinds live in separate arrays on
    /// disk (for the reasons ``UnsubscribeActionRecord`` sets out) and "what has InboxSweep
    /// done, in order" is a question about the screen rather than about the file. The identifier
    /// tiebreak makes the order total, so two entries written in the same second do not swap
    /// places between launches.
    static func merged(
        archives: [ActivityEntry],
        unsubscribes: [UnsubscribeActivityEntry]
    ) -> [ActivityTimelineEntry] {
        (archives.map(ActivityTimelineEntry.archive) + unsubscribes.map(ActivityTimelineEntry.unsubscribe))
            .sorted {
                $0.occurredAt == $1.occurredAt
                    ? $0.id.uuidString > $1.id.uuidString
                    : $0.occurredAt > $1.occurredAt
            }
    }
}

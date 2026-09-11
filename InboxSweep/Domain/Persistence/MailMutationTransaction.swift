import Foundation

/// One completed set mutation, durably enough recorded that its undo survives quitting the app.
///
/// This is the upgrade of the single-message record the previous interval wrote. The purpose is
/// still correctness and visibility, in that order — but "correctness" now has to reach across a
/// relaunch, because the offer to undo a twelve-message archive is worth more than the offer to
/// undo one message and a user who quits the app is not saying "never mind".
///
/// ### Why it names only the successes
///
/// ``succeededMessageIDs`` holds the messages the provider *confirmed*, and nothing else. That
/// is what makes undo safe to restore blindly: every identifier in here is a message this app
/// really did take out of somebody's inbox, so putting them back is undoing exactly what was
/// done. A partial run therefore produces a transaction for its successful subset — eight IDs
/// for eight archived messages — and the four that failed are counted, not named, because there
/// is nothing to undo about a message that never changed.
///
/// ### What is deliberately absent
///
/// No subject, no sender, no date received, no labels, no body — the last of which
/// ``MailMessage`` has nowhere to hold in the first place. The mailbox cache already holds the
/// metadata for every message in the loaded window, so copying subjects in here would put the
/// same mailbox content in a second file for no gain. A transaction *names* messages; the
/// window describes them.
///
/// ### It is also the Activity history
///
/// The same records answer "what has InboxSweep changed in my mailbox?" on the Activity screen.
/// That is a second job for one file rather than a second file, deliberately: a separate audit
/// store would be the same identifiers written twice, free to disagree with the transactions
/// undo actually acts on. It does mean the record has to survive being *used* — a partial undo
/// narrows ``succeededMessageIDs`` so the remaining offer is accurate, and
/// ``confirmedMessageCount`` is what keeps the history from being rewritten underneath it.
///
/// What it records is only what this app attempted or was told about. A message archived in
/// Gmail itself never appears here, however plainly the next refresh shows it left the inbox:
/// InboxSweep reconciles the mailbox it can see and does not invent a transaction it did not
/// perform.
///
/// This is not analytics. Nothing here is aggregated, scored, or sent anywhere, and the store
/// keeps a bounded, deterministic number of entries per account — see ``MailMutationHistory``.
nonisolated struct MailMutationTransaction: Identifiable, Hashable, Sendable {

    /// The logical mutation this transaction is for.
    ///
    /// Comes from ``MailArchiveSelection/operationID``, which is what makes a repeated
    /// submission of one confirmation overwrite one transaction instead of appending a second.
    let id: UUID

    /// Which operation was performed.
    let operation: MailMutationOperation

    /// The account it was performed against, so a transaction can never be read back against a
    /// different mailbox. Checked again before an undo is offered *and* before it is sent.
    let accountAddress: String

    /// The messages the provider confirmed **and that are still in that state** — the only ones
    /// an undo may name.
    ///
    /// Narrows when an undo partially succeeds: the messages that came back are no longer
    /// archived, so naming them again would be asking Gmail to restore something already
    /// restored. What that narrowing must not do is rewrite the *history*, which is what
    /// ``confirmedMessageCount`` is for.
    let succeededMessageIDs: [MailMessageID]

    /// How many messages the user confirmed, including the ones that failed.
    ///
    /// Kept so the audit line can say "10 selected, 8 archived" rather than quietly presenting
    /// eight as the whole story.
    let selectedMessageCount: Int

    /// How many messages this operation confirmed **when it ran**.
    ///
    /// A historical fact, fixed at the moment the provider answered, and the field the Activity
    /// screen counts from.
    ///
    /// It exists because ``succeededMessageIDs`` is a live list and history is not. Archive ten
    /// of ten, undo four of them, and the identifier list is down to six — so a screen counting
    /// that list would say "archived 6 of 10", which is a partial archive that never happened.
    /// The archive confirmed ten. Four of them were later put back, and that is a different
    /// sentence about a different operation.
    let confirmedMessageCount: Int

    /// When the operation finished.
    let occurredAt: Date

    /// What caused this operation to happen.
    ///
    /// Added in Interval 11, when a second thing could cause one. Until then every transaction in
    /// this file was the result of somebody pressing a confirming button, so "why did this
    /// happen?" had one answer and did not need recording. A local sender rule can now archive a
    /// message without anybody present, and an Activity screen that could not tell the two apart
    /// would be answering the wrong question: "3 messages archived" is a very different thing to
    /// read depending on whether you did it.
    ///
    /// A record written before this field existed decodes as ``MailMutationOrigin/confirmed``,
    /// which is exactly what it was: rules did not exist, so nothing in an older file could have
    /// come from one.
    let origin: MailMutationOrigin

    /// Whether this transaction is still the one an undo would act on.
    private(set) var undoState: UndoState

    /// - Parameter confirmedMessageCount: How many the operation confirmed when it ran. Defaults
    ///   to the number of identifiers, which is correct for every transaction that has not since
    ///   been partly undone — and is what a record written before this field existed means.
    ///   Never allowed to be smaller than the list it describes.
    init(
        id: UUID,
        operation: MailMutationOperation,
        accountAddress: String,
        succeededMessageIDs: [MailMessageID],
        selectedMessageCount: Int,
        occurredAt: Date,
        undoState: UndoState,
        confirmedMessageCount: Int? = nil,
        origin: MailMutationOrigin = .confirmed
    ) {
        self.id = id
        self.operation = operation
        self.accountAddress = accountAddress
        self.succeededMessageIDs = succeededMessageIDs
        self.selectedMessageCount = selectedMessageCount
        self.occurredAt = occurredAt
        self.undoState = undoState
        self.origin = origin
        self.confirmedMessageCount = max(
            confirmedMessageCount ?? succeededMessageIDs.count,
            succeededMessageIDs.count
        )
    }

    /// Where a transaction sits in the undo lifecycle.
    ///
    /// An explicit stored state rather than something inferred at read time, because the
    /// inference would have to be re-derived identically in every place that reads the file —
    /// and the one place it mattered would eventually get it wrong.
    nonisolated enum UndoState: String, Hashable, Sendable, CaseIterable {

        /// The offer stands. **At most one transaction per account is ever in this state.**
        case undoable

        /// Its messages have been put back, so there is nothing left to undo.
        case undone

        /// A later archive replaced it as the account's undo offer.
        ///
        /// Kept in the file rather than deleted: it is still a true record of what the app did
        /// to somebody's mailbox, and the audit history is the reason the file exists at all.
        case superseded

        /// It was never undoable — a restore, or an archive that confirmed nothing.
        case notUndoable
    }

    // MARK: - Derived

    /// Whether this is the transaction an undo would act on right now.
    var isUndoable: Bool { undoState == .undoable && !succeededMessageIDs.isEmpty }

    /// How many messages this transaction can still undo.
    ///
    /// The *live* count, which is not the same as what the operation did — see
    /// ``confirmedMessageCount``. Use this to describe an undo offer and that one to describe
    /// history.
    var succeededCount: Int { succeededMessageIDs.count }

    /// How many of the selected messages the provider refused or never saw.
    ///
    /// Counted from ``confirmedMessageCount`` rather than from the live identifier list, so a
    /// later partial undo cannot retroactively turn a complete archive into a failed one.
    var failedMessageCount: Int { max(selectedMessageCount - confirmedMessageCount, 0) }

    /// How many of this archive's messages have since been put back.
    ///
    /// The difference between what the operation confirmed and what it can still undo, which is
    /// exactly the set an undo has already restored.
    var restoredMessageCount: Int { max(confirmedMessageCount - succeededCount, 0) }

    /// Whether an undo has put some of this archive's messages back, but not all of them.
    var isPartiallyUndone: Bool {
        operation == .archive && restoredMessageCount > 0 && succeededCount > 0
    }

    /// The single message, when this transaction named exactly one.
    ///
    /// A set of one is the ordinary case — a user archiving a single message — and this is what
    /// lets the confirmation sheet and the tests talk about it in the singular without
    /// special-casing the whole model.
    var messageID: MailMessageID? {
        succeededMessageIDs.count == 1 ? succeededMessageIDs[0] : nil
    }

    /// Whether the provider confirmed every message the user selected, **when this ran**.
    ///
    /// Fixed for the life of the record. A partial archive stays partial and a complete one
    /// stays complete, whatever is undone afterwards, because this describes the operation and
    /// not the mailbox's state today.
    var outcome: Outcome {
        if confirmedMessageCount == 0 { return .failed }
        return failedMessageCount == 0 ? .confirmed : .partiallyConfirmed
    }

    /// Whether this operation did only part of what was asked.
    var isPartial: Bool { outcome == .partiallyConfirmed }

    /// Whether every selected message went through.
    ///
    /// Failures are recorded too. An attempt Gmail rejected is a fact about what the app tried
    /// to do, and a file that only kept the successes would be a worse answer to "what has
    /// InboxSweep done to my mailbox?" than no file at all.
    nonisolated enum Outcome: String, Hashable, Sendable, CaseIterable {
        case confirmed
        case partiallyConfirmed
        case failed
    }

    var isConfirmed: Bool { outcome == .confirmed }

    // MARK: - Activity

    /// Where this transaction stands, as the Activity screen needs to say it.
    ///
    /// One value derived in one place, rather than each screen re-deriving it out of
    /// ``undoState``, ``operation``, and three counts — which is how two screens end up
    /// disagreeing about whether an archive was undone.
    ///
    /// Every case describes something InboxSweep *attempted or was told about*. There is no case
    /// meaning "your mailbox looks like this now", because that is not a question a local record
    /// of past operations can answer.
    nonisolated enum ActivityStatus: String, Hashable, Sendable, CaseIterable {

        /// An archive whose messages can still be put back.
        case undoAvailable

        /// An archive a later one replaced as the account's undo offer. Its messages are still
        /// archived; there is simply no standing offer to reverse it.
        case undoSuperseded

        /// Every message this archive confirmed has been put back.
        case undoCompleted

        /// Some of this archive's messages have been put back and some have not.
        case undoPartiallyCompleted

        /// A restore — the record of an undo, which is not itself undoable.
        case restore

        /// An operation the provider confirmed nothing for. Nothing changed, so there is nothing
        /// to reverse.
        case nothingChanged
    }

    var activityStatus: ActivityStatus {
        guard operation == .archive else { return .restore }
        guard confirmedMessageCount > 0 else { return .nothingChanged }

        switch undoState {
        case .undoable:
            // A narrowed offer — some already put back, some not — is both at once, and the
            // partial reading is the more informative of the two.
            return isPartiallyUndone ? .undoPartiallyCompleted : .undoAvailable
        case .undone:
            return restoredMessageCount < confirmedMessageCount ? .undoPartiallyCompleted : .undoCompleted
        case .superseded:
            return isPartiallyUndone ? .undoPartiallyCompleted : .undoSuperseded
        case .notUndoable:
            return isPartiallyUndone ? .undoPartiallyCompleted : .undoSuperseded
        }
    }

    // MARK: - Transitions

    /// The same transaction, moved to a new point in the undo lifecycle.
    func settingUndoState(_ state: UndoState) -> MailMutationTransaction {
        var updated = self
        updated.undoState = state
        return updated
    }

    /// The same transaction with its undo offer narrowed to the messages still archived.
    ///
    /// What a partial undo produces. The identifiers shrink to those that did *not* come back,
    /// so a second undo asks Gmail only about messages that are still out of the inbox — and
    /// ``confirmedMessageCount``, ``selectedMessageCount``, and ``occurredAt`` are carried
    /// through untouched, because none of them is a statement about now. The archive still
    /// archived what it archived.
    func narrowingUndoOffer(to remaining: [MailMessageID]) -> MailMutationTransaction {
        MailMutationTransaction(
            id: id,
            operation: operation,
            accountAddress: accountAddress,
            succeededMessageIDs: remaining,
            selectedMessageCount: selectedMessageCount,
            occurredAt: occurredAt,
            undoState: remaining.isEmpty ? .undone : .undoable,
            confirmedMessageCount: confirmedMessageCount,
            origin: origin
        )
    }

    /// The transaction a finished run produces.
    ///
    /// Only an ``MailMutationOperation/archive`` that confirmed something is undoable. A
    /// restore is recorded as ``UndoState/notUndoable`` on purpose: its inverse is archiving
    /// again, and archiving is something the user asks for explicitly rather than something an
    /// "undo the undo" button does for them.
    ///
    /// ### Why a rule-driven archive is not undoable
    ///
    /// `origin` is the only thing that decides it, and it decides it deliberately. The app keeps
    /// **at most one undoable transaction per account**: a new archive supersedes the previous
    /// offer. That invariant is safe while every archive is something a person just did, because
    /// the offer they lose is one they replaced on purpose. A rule is not that. It runs on every
    /// load, without anybody asking, so letting it take the offer would mean a user's deliberate
    /// twelve-message undo quietly disappearing because they pressed Reload and two newsletters
    /// arrived.
    ///
    /// The alternative — a second, parallel undo offer — is a bigger change to the lifecycle than
    /// this feature earns, and a screen offering two undos is a screen where somebody presses the
    /// wrong one.
    ///
    /// So a rule-driven archive is recorded, counted, listed, and attributed to its rule, and it
    /// carries no undo. Nothing is fabricated in its place: Activity says there is none and says
    /// why, and archived mail is still in All Mail where Gmail's own **Move to Inbox** will put it
    /// back. See ``Docs/Rules.md``.
    static func completing(
        _ receipt: MailArchiveSetReceipt,
        at occurredAt: Date,
        origin: MailMutationOrigin = .confirmed
    ) -> MailMutationTransaction {
        let confirmed = receipt.confirmedMessageIDs
        let undoable = receipt.operation == .archive && !confirmed.isEmpty && origin.isUndoable
        return MailMutationTransaction(
            id: receipt.operationID,
            operation: receipt.operation,
            accountAddress: receipt.accountAddress,
            succeededMessageIDs: confirmed,
            selectedMessageCount: receipt.selectedCount,
            occurredAt: occurredAt,
            undoState: undoable ? .undoable : .notUndoable,
            confirmedMessageCount: confirmed.count,
            origin: origin
        )
    }
}

/// What caused a mutation, kept distinct because the three are different promises to the user.
///
/// Requirement 20 of Interval 11: the history must not collapse "I ticked these twelve and
/// pressed Archive", "I opened a sender's review, kept what it suggested, and pressed Archive",
/// and "a rule I authorized last month archived this while I was reading something else" into one
/// undifferentiated row. All three are honest archives through the same boundary; only the last
/// one happened without a person in the room.
nonisolated enum MailMutationOrigin: Hashable, Sendable {

    /// Somebody ticked a list of messages and confirmed it.
    case confirmed

    /// The same, reached from a sender-level review that filled the ticks in first.
    ///
    /// Still an explicit confirmation, and recorded separately because the *selection* was the
    /// app's suggestion rather than the user's own reading of the list. Nobody's mail is treated
    /// differently for it; the record simply says where the set came from.
    case senderReviewed

    /// A local sender rule archived it while InboxSweep was loading mail.
    ///
    /// Carries the rule so Activity can name which authorization was acted on, and so a rule the
    /// user later deletes still has its history attributable.
    case rule(SenderRule.ID)

    /// Whether an operation from this origin may become the account's undo offer.
    ///
    /// See ``MailMutationTransaction/completing(_:at:origin:)`` for why a rule's may not.
    var isUndoable: Bool {
        switch self {
        case .confirmed, .senderReviewed: true
        case .rule: false
        }
    }

    /// Whether InboxSweep did this without anybody present.
    var wasAutomatic: Bool {
        if case .rule = self { return true }
        return false
    }

    /// The rule behind this operation, when there was one.
    var ruleID: SenderRule.ID? {
        if case .rule(let id) = self { return id }
        return nil
    }

    /// The stored form. Parsed back strictly: an origin this build does not recognise is not one
    /// it wrote, and the decoder drops the entry rather than guessing which of the three it meant.
    var storedValue: String {
        switch self {
        case .confirmed: "confirmed"
        case .senderReviewed: "senderReviewed"
        case .rule(let id): "rule:\(id.uuidString)"
        }
    }

    /// Rebuilds an origin from ``storedValue``, or `nil` for anything this build did not write.
    static func decoding(_ stored: String?) -> MailMutationOrigin? {
        guard let stored else { return .confirmed }
        switch stored {
        case "confirmed": return .confirmed
        case "senderReviewed": return .senderReviewed
        default:
            guard stored.hasPrefix("rule:"), let id = UUID(uuidString: String(stored.dropFirst(5))) else {
                return nil
            }
            return .rule(id)
        }
    }
}

/// Whether a transaction made it to disk.
///
/// Reported rather than swallowed, because the one thing this distinction protects is the
/// sentence "your messages were archived but this Mac couldn't write that down". Reporting a
/// confirmed remote change as a failure — which is what a silent local error would lead to —
/// would be telling the user the opposite of what happened to their mailbox.
///
/// It matters more than it did for a single message: the undo offer is now *read back from this
/// file* after a relaunch, so a write that did not land is also the offer quietly not being
/// there next launch. The warning says so.
nonisolated enum MutationRecordOutcome: Equatable, Sendable {

    case stored

    /// `reason` is a short, secret-free sentence.
    case notStored(reason: String)

    var isStored: Bool { self == .stored }

    var warning: String? {
        guard case .notStored(let reason) = self else { return nil }
        return reason
    }
}

/// Local storage for ``MailMutationTransaction``.
///
/// Implementations keep at most one account's transactions at a time, for the same reason the
/// mailbox cache does: signing into a second account must not leave the first one's history
/// behind.
nonisolated protocol MailMutationRecording: Sendable {

    /// Writes a transaction, replacing any earlier one with the same
    /// ``MailMutationTransaction/id``.
    ///
    /// Replacing rather than appending is what makes this safe to call more than once for one
    /// logical mutation — a repeated completion updates the transaction it already wrote — and
    /// it is also how the undo lifecycle is persisted: superseding one and marking another
    /// undone are both just writes of an already-known ID.
    func record(_ transaction: MailMutationTransaction) async -> MutationRecordOutcome

    /// The stored transactions for `account`, newest first.
    func transactions(for account: MailAccount) async -> [MailMutationTransaction]

    /// Removes the stored transactions for `account`.
    func clear(for account: MailAccount) async

    /// Writes an unsubscribe entry, replacing any earlier one with the same identifier.
    ///
    /// A **separate method** rather than a `record(_ entry: some ActivityRecord)` that took
    /// either. The two kinds of entry have different shapes, different lifecycles, and — the
    /// part that matters — different powers: a transaction can be read back and turned into
    /// requests that put messages back in an inbox, and an unsubscribe entry can be read back
    /// and turned into nothing at all, because it has no inverse. A single generic method would
    /// have invited a single generic handler for both.
    ///
    /// Replacing by identifier for the same reason: one confirmation is one entry, whether it
    /// is completed once or reported twice.
    func record(_ entry: UnsubscribeActionRecord) async -> MutationRecordOutcome

    /// The stored unsubscribe entries for `account`, newest first.
    func unsubscribeEntries(for account: MailAccount) async -> [UnsubscribeActionRecord]
}

nonisolated extension MailMutationRecording {

    /// Unsubscribe history is optional for a store to implement.
    ///
    /// Defaulted so a store written for archive history alone — and the test doubles that are —
    /// keeps compiling and keeps reporting honestly: nothing stored, and a write that says so.
    func record(_ entry: UnsubscribeActionRecord) async -> MutationRecordOutcome {
        .notStored(reason: "This mailbox doesn't keep a record of unsubscribe actions.")
    }

    func unsubscribeEntries(for account: MailAccount) async -> [UnsubscribeActionRecord] { [] }

    /// The one transaction `account` could still undo, if there is one.
    ///
    /// Derived from ``transactions(for:)`` rather than being a protocol method of its own, so
    /// "at most one undoable transaction per account" is a single rule enforced in a single
    /// place regardless of which store is underneath.
    ///
    /// Defensive about `undoable` appearing more than once — which the writer never produces,
    /// but a hand-edited or half-written file could. The newest wins and the rest are ignored
    /// rather than the app offering two undos it cannot both honour.
    func latestUndoableTransaction(for account: MailAccount) async -> MailMutationTransaction? {
        await transactions(for: account)
            .first { $0.isUndoable && $0.accountAddress == account.emailAddress.address }
    }
}

/// A transaction store that keeps everything in memory and nothing on disk.
///
/// The default, so persistence is opted into rather than assumed — and what the synthetic
/// mailbox runs on, since invented mail has no business leaving a trail in a real container.
nonisolated final class EphemeralMutationRecordStore: MailMutationRecording, @unchecked Sendable {

    private let lock = NSLock()
    private var stored: [MailMutationTransaction] = []
    private var storedUnsubscribes: [UnsubscribeActionRecord] = []

    init() {}

    /// Starts with transactions already in it.
    ///
    /// Exists so a store can be handed to a session *fully populated* rather than filled in by an
    /// `await` the caller has to sequence before connecting. Used by the synthetic-mailbox
    /// Activity fixture and by tests that describe a relaunch.
    init(
        seeded transactions: [MailMutationTransaction],
        unsubscribes: [UnsubscribeActionRecord] = []
    ) {
        stored = transactions
        storedUnsubscribes = unsubscribes
    }

    func record(_ transaction: MailMutationTransaction) async -> MutationRecordOutcome {
        lock.withLock {
            stored.removeAll { $0.id == transaction.id }
            stored.append(transaction)
        }
        return .stored
    }

    func transactions(for account: MailAccount) async -> [MailMutationTransaction] {
        // The same retention policy the file store applies, so a session running on synthetic
        // mail and one running on a real mailbox produce the same history for the same actions.
        lock.withLock { MailMutationHistory.history(stored, for: account) }
    }

    func clear(for account: MailAccount) async {
        lock.withLock {
            stored.removeAll { $0.accountAddress == account.emailAddress.address }
            storedUnsubscribes.removeAll { $0.accountAddress == account.emailAddress.address }
        }
    }

    func record(_ entry: UnsubscribeActionRecord) async -> MutationRecordOutcome {
        lock.withLock {
            storedUnsubscribes.removeAll { $0.id == entry.id }
            storedUnsubscribes.append(entry)
        }
        return .stored
    }

    func unsubscribeEntries(for account: MailAccount) async -> [UnsubscribeActionRecord] {
        lock.withLock { MailMutationHistory.unsubscribeHistory(storedUnsubscribes, for: account) }
    }
}

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
/// This is not analytics. Nothing here is aggregated, scored, or sent anywhere, and the store
/// keeps a bounded number of the most recent entries rather than a history.
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

    /// The messages the provider confirmed — the only ones an undo may name.
    let succeededMessageIDs: [MailMessageID]

    /// How many messages the user confirmed, including the ones that failed.
    ///
    /// Kept so the audit line can say "10 selected, 8 archived" rather than quietly presenting
    /// eight as the whole story.
    let selectedMessageCount: Int

    /// When the operation finished.
    let occurredAt: Date

    /// Whether this transaction is still the one an undo would act on.
    private(set) var undoState: UndoState

    init(
        id: UUID,
        operation: MailMutationOperation,
        accountAddress: String,
        succeededMessageIDs: [MailMessageID],
        selectedMessageCount: Int,
        occurredAt: Date,
        undoState: UndoState
    ) {
        self.id = id
        self.operation = operation
        self.accountAddress = accountAddress
        self.succeededMessageIDs = succeededMessageIDs
        self.selectedMessageCount = selectedMessageCount
        self.occurredAt = occurredAt
        self.undoState = undoState
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

    var succeededCount: Int { succeededMessageIDs.count }

    /// How many of the confirmed messages the provider refused.
    var failedMessageCount: Int { max(selectedMessageCount - succeededCount, 0) }

    /// The single message, when this transaction named exactly one.
    ///
    /// A set of one is the ordinary case — a user archiving a single message — and this is what
    /// lets the confirmation sheet and the tests talk about it in the singular without
    /// special-casing the whole model.
    var messageID: MailMessageID? {
        succeededMessageIDs.count == 1 ? succeededMessageIDs[0] : nil
    }

    /// Whether the provider confirmed every message the user selected.
    var outcome: Outcome {
        if succeededCount == 0 { return .failed }
        return failedMessageCount == 0 ? .confirmed : .partiallyConfirmed
    }

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

    // MARK: - Transitions

    /// The same transaction, moved to a new point in the undo lifecycle.
    func settingUndoState(_ state: UndoState) -> MailMutationTransaction {
        var updated = self
        updated.undoState = state
        return updated
    }

    /// The transaction a finished run produces.
    ///
    /// Only an ``MailMutationOperation/archive`` that confirmed something is undoable. A
    /// restore is recorded as ``UndoState/notUndoable`` on purpose: its inverse is archiving
    /// again, and archiving is something the user asks for explicitly rather than something an
    /// "undo the undo" button does for them.
    static func completing(
        _ receipt: MailArchiveSetReceipt,
        at occurredAt: Date
    ) -> MailMutationTransaction {
        let confirmed = receipt.confirmedMessageIDs
        let undoable = receipt.operation == .archive && !confirmed.isEmpty
        return MailMutationTransaction(
            id: receipt.operationID,
            operation: receipt.operation,
            accountAddress: receipt.accountAddress,
            succeededMessageIDs: confirmed,
            selectedMessageCount: receipt.selectedCount,
            occurredAt: occurredAt,
            undoState: undoable ? .undoable : .notUndoable
        )
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
}

nonisolated extension MailMutationRecording {

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

    init() {}

    func record(_ transaction: MailMutationTransaction) async -> MutationRecordOutcome {
        lock.withLock {
            stored.removeAll { $0.id == transaction.id }
            stored.append(transaction)
        }
        return .stored
    }

    func transactions(for account: MailAccount) async -> [MailMutationTransaction] {
        lock.withLock {
            stored
                .filter { $0.accountAddress == account.emailAddress.address }
                .sorted { $0.occurredAt > $1.occurredAt }
        }
    }

    func clear(for account: MailAccount) async {
        lock.withLock {
            stored.removeAll { $0.accountAddress == account.emailAddress.address }
        }
    }
}

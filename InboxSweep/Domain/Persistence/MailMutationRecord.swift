import Foundation

/// One line in the local record of what InboxSweep changed.
///
/// The purpose is correctness and visibility, in that order. Undo needs the provider message
/// identifier and the account it belongs to; the user needs to be able to see that InboxSweep
/// changed exactly the things it said it changed, and nothing else. Neither purpose needs the
/// mail itself.
///
/// ### What is deliberately absent
///
/// No subject, no sender, no date received, no body — the last of which ``MailMessage`` has
/// nowhere to hold in the first place. The cache already holds the metadata for every message
/// in the loaded window, so copying a subject in here would put the same mailbox content in a
/// second file for no gain. A record names a message; the window describes it.
///
/// This is not analytics. Nothing here is aggregated, scored, or sent anywhere, and the store
/// keeps a bounded number of the most recent entries rather than a history.
nonisolated struct MailMutationRecord: Identifiable, Hashable, Sendable {

    /// The logical mutation this record is for.
    ///
    /// Comes from ``MailArchiveRequest/operationID``, which is what makes a repeated submission
    /// of the same user action overwrite one record instead of appending a second.
    let id: UUID

    /// Which operation was attempted.
    let operation: MailMutationOperation

    /// The provider's identifier for the message — the one thing undo cannot work without.
    let messageID: MailMessageID

    /// The account the mutation was performed against, so a record can never be read back
    /// against a different mailbox.
    let accountAddress: String

    /// When the attempt finished.
    let occurredAt: Date

    /// Whether the provider confirmed it.
    let outcome: Outcome

    init(
        id: UUID,
        operation: MailMutationOperation,
        messageID: MailMessageID,
        accountAddress: String,
        occurredAt: Date,
        outcome: Outcome
    ) {
        self.id = id
        self.operation = operation
        self.messageID = messageID
        self.accountAddress = accountAddress
        self.occurredAt = occurredAt
        self.outcome = outcome
    }

    /// Whether the provider confirmed the change, or refused it.
    ///
    /// Failures are recorded too. An attempt that Gmail rejected is a fact about what the app
    /// tried to do, and a record that only kept the successes would be a worse answer to
    /// "what has InboxSweep done to my mailbox?" than no record at all.
    nonisolated enum Outcome: String, Hashable, Sendable, CaseIterable {
        case confirmed
        case failed
    }

    var isConfirmed: Bool { outcome == .confirmed }
}

/// Whether a record made it to disk.
///
/// Reported rather than swallowed, because the one thing this distinction protects is the
/// sentence "your message was archived but this Mac couldn't write that down". Reporting a
/// confirmed remote change as a failure — which is what a silent local error would lead to —
/// would be telling the user the opposite of what happened to their mailbox.
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

/// Local storage for ``MailMutationRecord``.
///
/// Implementations keep at most one account's records at a time, for the same reason the
/// mailbox cache does: signing into a second account must not leave the first one's history
/// behind.
nonisolated protocol MailMutationRecording: Sendable {

    /// Writes a record, replacing any earlier one with the same ``MailMutationRecord/id``.
    ///
    /// Replacing rather than appending is what makes this safe to call more than once for one
    /// logical mutation — a repeated completion callback updates the record it already wrote.
    func record(_ record: MailMutationRecord) async -> MutationRecordOutcome

    /// The stored records for `account`, newest first.
    func records(for account: MailAccount) async -> [MailMutationRecord]

    /// Removes the stored records for `account`.
    func clear(for account: MailAccount) async
}

/// A record store that keeps everything in memory and nothing on disk.
///
/// The default, so persistence is opted into rather than assumed — and what the synthetic
/// mailbox runs on, since invented mail has no business leaving a trail in a real container.
nonisolated final class EphemeralMutationRecordStore: MailMutationRecording, @unchecked Sendable {

    private let lock = NSLock()
    private var stored: [MailMutationRecord] = []

    init() {}

    func record(_ record: MailMutationRecord) async -> MutationRecordOutcome {
        lock.withLock {
            stored.removeAll { $0.id == record.id }
            stored.append(record)
        }
        return .stored
    }

    func records(for account: MailAccount) async -> [MailMutationRecord] {
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

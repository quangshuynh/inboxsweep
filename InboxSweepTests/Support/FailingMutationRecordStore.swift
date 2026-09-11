import Foundation
@testable import InboxSweep

/// A record store that refuses to write, for the one outcome that must not be reported as a
/// remote failure: Gmail changed the mailbox and this Mac could not write that down.
nonisolated final class FailingMutationRecordStore: MailMutationRecording, @unchecked Sendable {

    static let refusalReason = "InboxSweep couldn't write the record to this Mac."

    private let lock = NSLock()
    private var attempted: [MailMutationRecord] = []

    /// Everything it was asked to store, even though it stored none of it.
    var attemptedRecords: [MailMutationRecord] { lock.withLock { attempted } }

    init() {}

    func record(_ record: MailMutationRecord) async -> MutationRecordOutcome {
        lock.withLock { attempted.append(record) }
        return .notStored(reason: Self.refusalReason)
    }

    func records(for account: MailAccount) async -> [MailMutationRecord] { [] }
    func clear(for account: MailAccount) async {}
}

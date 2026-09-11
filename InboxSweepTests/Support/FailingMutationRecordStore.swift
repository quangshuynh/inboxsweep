import Foundation
@testable import InboxSweep

/// A transaction store that refuses to write, for the one outcome that must not be reported as a
/// remote failure: Gmail changed the mailbox and this Mac could not write that down.
nonisolated final class FailingMutationRecordStore: MailMutationRecording, @unchecked Sendable {

    static let refusalReason = "InboxSweep couldn't write the record to this Mac."

    private let lock = NSLock()
    private var attempted: [MailMutationTransaction] = []

    /// Everything it was asked to store, even though it stored none of it.
    var attemptedTransactions: [MailMutationTransaction] { lock.withLock { attempted } }

    init() {}

    func record(_ transaction: MailMutationTransaction) async -> MutationRecordOutcome {
        lock.withLock { attempted.append(transaction) }
        return .notStored(reason: Self.refusalReason)
    }

    func transactions(for account: MailAccount) async -> [MailMutationTransaction] { [] }
    func clear(for account: MailAccount) async {}
}

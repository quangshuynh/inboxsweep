import Foundation
@testable import InboxSweep

/// A programmable mutation boundary, for exercising the session without Gmail.
///
/// Implements the same protocol the Gmail adapter does, so the session tests describe behaviour
/// the app would really get from a provider rather than behaviour shaped around the
/// implementation. It records every request it is handed, which is what lets a test assert the
/// things that matter most about a write: that exactly one went out, that it named the message
/// the user picked, and that it carried the account the window belongs to.
actor StubMessageArchiver: MailMessageArchiving {

    enum Behavior: Sendable {
        case succeeds
        case fails(MailMutationError)
        /// Never returns on its own, for exercising the in-flight guard.
        case stalls
    }

    private var capability: MailMutationCapability
    private var archiveBehavior: Behavior
    private var undoBehavior: Behavior

    /// What ``authorizeArchiving()`` results in.
    private var upgradeResult: Result<MailMutationCapability, MailMutationError>

    /// The labels a receipt reports, keyed by message ID, so the session's reconciliation has
    /// something realistic to reconcile against.
    private var labelsByMessage: [MailMessageID: Set<MailLabel>] = [:]

    /// The address this archiver considers itself authenticated for.
    private var authenticatedAddress: String

    private(set) var archiveRequests: [MailArchiveRequest] = []
    private(set) var undoRequests: [MailArchiveRequest] = []
    private(set) var upgradeCallCount = 0
    private(set) var capabilityCallCount = 0

    init(
        capability: MailMutationCapability = .granted,
        archiveBehavior: Behavior = .succeeds,
        undoBehavior: Behavior = .succeeds,
        upgradeResult: Result<MailMutationCapability, MailMutationError> = .success(.granted),
        authenticatedAddress: String = MailAccount.testAccount.emailAddress.address,
        labelsByMessage: [MailMessageID: Set<MailLabel>] = [:]
    ) {
        self.capability = capability
        self.archiveBehavior = archiveBehavior
        self.undoBehavior = undoBehavior
        self.upgradeResult = upgradeResult
        self.authenticatedAddress = authenticatedAddress
        self.labelsByMessage = labelsByMessage
    }

    /// Every request this archiver was asked to perform, in order — the basis for asserting
    /// that a double submission produced one call rather than two.
    var allRequests: [MailArchiveRequest] { archiveRequests + undoRequests }

    // MARK: - MailMessageArchiving

    func archiveCapability() async -> MailMutationCapability {
        capabilityCallCount += 1
        return capability
    }

    func authorizeArchiving() async throws -> MailMutationCapability {
        upgradeCallCount += 1
        switch upgradeResult {
        case .success(let granted):
            capability = granted
            return granted
        case .failure(let error):
            throw error
        }
    }

    func archive(_ request: MailArchiveRequest) async throws -> MailArchiveReceipt {
        archiveRequests.append(request)
        return try await perform(.archive, request, behavior: archiveBehavior)
    }

    func restoreToInbox(_ request: MailArchiveRequest) async throws -> MailArchiveReceipt {
        undoRequests.append(request)
        return try await perform(.restoreToInbox, request, behavior: undoBehavior)
    }

    // MARK: - Programming

    func setCapability(_ capability: MailMutationCapability) { self.capability = capability }
    func setArchiveBehavior(_ behavior: Behavior) { archiveBehavior = behavior }
    func setUndoBehavior(_ behavior: Behavior) { undoBehavior = behavior }
    func setAuthenticatedAddress(_ address: String) { authenticatedAddress = address }
    func setLabels(_ labels: Set<MailLabel>, for id: MailMessageID) { labelsByMessage[id] = labels }

    // MARK: - Internals

    private func perform(
        _ operation: MailMutationOperation,
        _ request: MailArchiveRequest,
        behavior: Behavior
    ) async throws -> MailArchiveReceipt {
        // The real adapter checks this before anything else, so the stub does too — otherwise a
        // session test could pass while relying on a boundary that never validated anything.
        guard request.accountAddress == authenticatedAddress else {
            throw MailMutationError.accountChanged
        }

        switch behavior {
        case .fails(let error):
            throw error
        case .stalls:
            try await Task.sleep(for: .seconds(60))
            throw MailMutationError.cancelled
        case .succeeds:
            break
        }

        var labels = labelsByMessage[request.messageID] ?? [.inbox]
        switch operation {
        case .archive: labels.remove(.inbox)
        case .restoreToInbox: labels.insert(.inbox)
        }
        labelsByMessage[request.messageID] = labels

        return MailArchiveReceipt(
            messageID: request.messageID,
            operation: operation,
            labelsAfterMutation: labels
        )
    }
}

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

import Foundation
@testable import InboxSweep

/// A programmable mutation boundary, for exercising the session without Gmail.
///
/// Implements the same protocol the Gmail adapter does, so the session tests describe behaviour
/// the app would really get from a provider rather than behaviour shaped around the
/// implementation. It records every request it is handed, which is what lets a test assert the
/// things that matter most about a write: that exactly one went out, that it named the message
/// the user picked, and that it carried the account the window belongs to.
///
/// A lock-guarded `final class` rather than an actor, matching ``RecordingHTTPTransport``: the
/// session already awaits every call, and its recorded state is then readable synchronously
/// from a test without an `await` that does nothing.
nonisolated final class StubMessageArchiver: MailMessageArchiving, @unchecked Sendable {

    enum Behavior: Sendable {
        case succeeds
        case fails(MailMutationError)
        /// Never returns on its own, for exercising the in-flight guard.
        case stalls
    }

    private let lock = NSLock()

    private var capability: MailMutationCapability
    private var archiveBehavior: Behavior
    private var undoBehavior: Behavior

    /// What ``authorizeArchiving()`` results in.
    private var upgradeResult: Result<MailMutationCapability, MailMutationError>

    /// The labels a receipt reports, keyed by message ID, so the session's reconciliation has
    /// something realistic to reconcile against — and so an archive followed by an undo reports
    /// the right thing both times.
    private var labelsByMessage: [MailMessageID: Set<MailLabel>]

    /// The address this archiver considers itself authenticated for.
    private var authenticatedAddress: String

    /// Behaviour for individual messages, overriding the blanket one.
    ///
    /// The basis for every partial-failure case: a set where message three is rate-limited and
    /// the rest succeed is the shape this suite has to be able to describe.
    private var behaviorByMessage: [MailMessageID: Behavior] = [:]

    private var recordedArchiveRequests: [MailArchiveRequest] = []
    private var recordedUndoRequests: [MailArchiveRequest] = []
    private var recordedUpgradeCallCount = 0
    private var recordedCapabilityCallCount = 0

    /// How many requests are with this archiver right now, and the most there have ever been.
    ///
    /// Tracked so "a set is sent one message at a time" is asserted rather than assumed. A
    /// high-water mark above one would mean the executor had started fanning out.
    private var inFlight = 0
    private var peakInFlight = 0

    init(
        capability: MailMutationCapability = .granted,
        archiveBehavior: Behavior = .succeeds,
        undoBehavior: Behavior = .succeeds,
        upgradeResult: Result<MailMutationCapability, MailMutationError> = .success(.granted),
        authenticatedAddress: String? = nil,
        labelsByMessage: [MailMessageID: Set<MailLabel>] = [:]
    ) {
        self.capability = capability
        self.archiveBehavior = archiveBehavior
        self.undoBehavior = undoBehavior
        self.upgradeResult = upgradeResult
        self.authenticatedAddress = authenticatedAddress ?? MailAccount.testAccount.emailAddress.address
        self.labelsByMessage = labelsByMessage
    }

    // MARK: - Inspection

    var archiveRequests: [MailArchiveRequest] { lock.withLock { recordedArchiveRequests } }
    var undoRequests: [MailArchiveRequest] { lock.withLock { recordedUndoRequests } }
    var upgradeCallCount: Int { lock.withLock { recordedUpgradeCallCount } }

    /// How many times the session asked what the grant currently covers.
    ///
    /// The basis for asserting that a permission change is re-derived from the provider rather
    /// than assumed from whatever `authorizeArchiving()` happened to return.
    var capabilityCallCount: Int { lock.withLock { recordedCapabilityCallCount } }

    /// Every request this archiver was asked to perform, in order — the basis for asserting
    /// that a double submission produced one call rather than two.
    var allRequests: [MailArchiveRequest] {
        lock.withLock { recordedArchiveRequests + recordedUndoRequests }
    }

    /// The most requests that were ever with this archiver at the same time.
    ///
    /// One, for every run this app can produce. `SafetyBoundaryTests` pins it there.
    var peakConcurrentRequests: Int { lock.withLock { peakInFlight } }

    // MARK: - Programming

    func setCapability(_ capability: MailMutationCapability) {
        lock.withLock { self.capability = capability }
    }

    func setArchiveBehavior(_ behavior: Behavior) {
        lock.withLock { archiveBehavior = behavior }
    }

    func setUndoBehavior(_ behavior: Behavior) {
        lock.withLock { undoBehavior = behavior }
    }

    func setAuthenticatedAddress(_ address: String) {
        lock.withLock { authenticatedAddress = address }
    }

    /// Programs one message, leaving every other one on the blanket behaviour.
    func setBehavior(_ behavior: Behavior, forMessage messageID: MailMessageID) {
        lock.withLock { behaviorByMessage[messageID] = behavior }
    }

    /// Resumes once at least `count` requests have been handed to this archiver.
    ///
    /// Replaces spinning on `Task.yield()` in tests that need to act in the middle of a run.
    func waitForRequests(atLeast count: Int) async {
        while lock.withLock({ recordedArchiveRequests.count + recordedUndoRequests.count }) < count {
            await Task.yield()
        }
    }

    // MARK: - MailMessageArchiving

    func archiveCapability() async -> MailMutationCapability {
        lock.withLock {
            recordedCapabilityCallCount += 1
            return capability
        }
    }

    func authorizeArchiving() async throws -> MailMutationCapability {
        let result = lock.withLock {
            recordedUpgradeCallCount += 1
            return upgradeResult
        }

        switch result {
        case .success(let granted):
            lock.withLock { capability = granted }
            return granted
        case .failure(let error):
            throw error
        }
    }

    func archive(_ request: MailArchiveRequest) async throws -> MailArchiveReceipt {
        let behavior = lock.withLock {
            recordedArchiveRequests.append(request)
            return behaviorByMessage[request.messageID] ?? archiveBehavior
        }
        return try await perform(.archive, request, behavior: behavior)
    }

    func restoreToInbox(_ request: MailArchiveRequest) async throws -> MailArchiveReceipt {
        let behavior = lock.withLock {
            recordedUndoRequests.append(request)
            return behaviorByMessage[request.messageID] ?? undoBehavior
        }
        return try await perform(.restoreToInbox, request, behavior: behavior)
    }

    // MARK: - Internals

    private func perform(
        _ operation: MailMutationOperation,
        _ request: MailArchiveRequest,
        behavior: Behavior
    ) async throws -> MailArchiveReceipt {
        lock.withLock {
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }

        // The real adapter checks this before anything else, so the stub does too — otherwise a
        // session test could pass while relying on a boundary that never validated anything.
        guard request.accountAddress == lock.withLock({ authenticatedAddress }) else {
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

        return lock.withLock {
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
}

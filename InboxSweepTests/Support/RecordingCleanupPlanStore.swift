import Foundation
@testable import InboxSweep

/// An in-memory plan store that records what the session asked of it.
///
/// Lets the session tests describe what happens to saved choices across a relaunch without
/// touching the file system, while ``SavedCleanupPlanTests`` covers the real file format
/// separately against ``FileCleanupPlanStore``.
///
/// A lock rather than an actor, matching ``FailingCredentialStore``: the store's whole job here
/// is a dictionary lookup, and keeping its counters readable without `await` keeps the tests
/// that assert on them readable too.
nonisolated final class RecordingCleanupPlanStore: CleanupPlanStoring, @unchecked Sendable {

    private let lock = NSLock()
    private var stored: [String: SavedCleanupPlan] = [:]
    private var loads = 0
    private var saves = 0
    private var clears = 0

    init(seeded: SavedCleanupPlan? = nil) {
        if let seeded {
            stored[Self.key(for: seeded.accountAddress)] = seeded
        }
    }

    var loadCallCount: Int { lock.withLock { loads } }
    var saveCallCount: Int { lock.withLock { saves } }
    var clearCallCount: Int { lock.withLock { clears } }

    func load(for account: MailAccount) async -> SavedCleanupPlan? {
        lock.withLock {
            loads += 1
            // The real store checks the account the plan was written for, not only the filename
            // it was found under; matching that here keeps the double from letting a
            // cross-account bug through that the file store would have caught.
            guard let plan = stored[Self.key(for: account.emailAddress.address)],
                  plan.belongs(to: account)
            else { return nil }
            return plan
        }
    }

    func save(_ plan: SavedCleanupPlan) async {
        lock.withLock {
            saves += 1
            // The real store keeps one account at a time.
            stored = [Self.key(for: plan.accountAddress): plan]
        }
    }

    func clear(for account: MailAccount) async {
        lock.withLock {
            clears += 1
            stored.removeValue(forKey: Self.key(for: account.emailAddress.address))
        }
    }

    /// What is currently stored for an address, without counting as a load.
    func storedPlan(forAddress address: String) -> SavedCleanupPlan? {
        lock.withLock { stored[Self.key(for: address)] }
    }

    private static func key(for address: String) -> String { address.lowercased() }
}

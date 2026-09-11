import Foundation
@testable import InboxSweep

/// An in-memory cache that records what the session asked of it.
///
/// Lets the session tests describe relaunch behaviour: "this launch read the stored window
/// and made no request", without touching the file system, while ``InboxCacheStoreTests``
/// covers the real file format separately.
actor RecordingInboxCache: InboxCacheStoring {

    private var stored: [String: CachedInbox] = [:]

    private(set) var loadCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var clearCallCount = 0

    /// The most recently saved window, which is what a relaunch would find.
    private(set) var lastSaved: CachedInbox?

    init(seeded: CachedInbox? = nil) {
        if let seeded {
            stored[Self.key(for: seeded.account)] = seeded
        }
    }

    func load(for account: MailAccount) async -> CachedInbox? {
        loadCallCount += 1
        return stored[Self.key(for: account)]
    }

    func save(_ inbox: CachedInbox) async {
        saveCallCount += 1
        lastSaved = inbox
        // The real store keeps one account at a time; matching that here keeps the double
        // from letting a bug through that the file store would have caught.
        stored = [Self.key(for: inbox.account): inbox]
    }

    func clear(for account: MailAccount) async {
        clearCallCount += 1
        stored.removeValue(forKey: Self.key(for: account))
    }

    /// What is currently stored for `account`, without counting as a load.
    func storedWindow(for account: MailAccount) -> CachedInbox? {
        stored[Self.key(for: account)]
    }

    private static func key(for account: MailAccount) -> String {
        account.emailAddress.address
    }
}

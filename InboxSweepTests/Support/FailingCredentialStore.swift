import Foundation
@testable import InboxSweep

/// A credential store that fails on demand, so the provider's error mapping can be exercised
/// without needing a Keychain in a particular broken state.
///
/// The real ``KeychainCredentialStore`` is covered by ``KeychainCredentialStoreTests`` against
/// the real Keychain. This double covers the other half: what the *provider* does when a store
/// says no — which is where the original defect lived, not in the Keychain calls themselves.
nonisolated final class FailingCredentialStore: GmailCredentialStoring, @unchecked Sendable {

    private let lock = NSLock()
    private var credentials: GmailStoredCredentials?
    private let loadError: CredentialStoreError?
    private let saveError: CredentialStoreError?
    private let clearError: CredentialStoreError?

    private(set) var saveCallCount = 0
    private(set) var clearCallCount = 0

    init(
        credentials: GmailStoredCredentials? = nil,
        loadError: CredentialStoreError? = nil,
        saveError: CredentialStoreError? = nil,
        clearError: CredentialStoreError? = nil
    ) {
        self.credentials = credentials
        self.loadError = loadError
        self.saveError = saveError
        self.clearError = clearError
    }

    func load() throws -> GmailStoredCredentials? {
        if let loadError { throw loadError }
        return lock.withLock { credentials }
    }

    func save(_ credentials: GmailStoredCredentials) throws {
        lock.withLock { saveCallCount += 1 }
        if let saveError { throw saveError }
        lock.withLock { self.credentials = credentials }
    }

    func clear() throws {
        lock.withLock { clearCallCount += 1 }
        // A store that refuses to delete keeps what it holds. That is the point: the provider
        // must not be able to report a sign-out as complete over a credential still in place.
        if let clearError { throw clearError }
        lock.withLock { credentials = nil }
    }
}

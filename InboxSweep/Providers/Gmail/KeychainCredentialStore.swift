import Foundation
import Security

/// Stores the Gmail refresh token in the macOS Keychain.
///
/// The Keychain is used rather than a file or `UserDefaults` so the refresh token is
/// protected by the system at rest and is not readable by other apps. It is scoped to this
/// app's own access group; no keychain sharing is requested.
nonisolated struct KeychainCredentialStore: GmailCredentialStoring {

    /// Anything the Keychain refuses to do, expressed in terms the UI can talk about.
    enum StoreError: Error, Equatable {
        case unhandled(status: OSStatus)
        case malformedStoredData
    }

    private let service: String
    private let account: String

    init(service: String = "InboxSweep.Gmail", account: String = "default") {
        self.service = service
        self.account = account
    }

    func load() throws -> GmailStoredCredentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw StoreError.malformedStoredData }
            do {
                return try JSONDecoder().decode(GmailStoredCredentials.self, from: data)
            } catch {
                // A stored blob we can no longer read is useless; drop it rather than
                // leaving the app permanently unable to sign in.
                try? clear()
                return nil
            }
        case errSecItemNotFound:
            return nil
        default:
            throw StoreError.unhandled(status: status)
        }
    }

    func save(_ credentials: GmailStoredCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query = baseQuery()

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }

        guard updateStatus == errSecItemNotFound else {
            throw StoreError.unhandled(status: updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError.unhandled(status: addStatus) }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unhandled(status: status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Opt in to the modern, app-scoped keychain rather than the legacy file keychain.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

/// A store that keeps credentials only for the lifetime of the process.
///
/// Used as a fallback when the Keychain is unavailable — for example in an unsigned build —
/// so sign-in still works for the current session instead of failing outright. The user is
/// simply asked to connect again next launch.
nonisolated final class InMemoryCredentialStore: GmailCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: GmailStoredCredentials?

    init(credentials: GmailStoredCredentials? = nil) {
        self.credentials = credentials
    }

    func load() throws -> GmailStoredCredentials? {
        lock.withLock { credentials }
    }

    func save(_ credentials: GmailStoredCredentials) throws {
        lock.withLock { self.credentials = credentials }
    }

    func clear() throws {
        lock.withLock { credentials = nil }
    }
}

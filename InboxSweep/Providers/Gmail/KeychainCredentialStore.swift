import Foundation
import Security

/// Stores the Gmail refresh token in the macOS Keychain.
///
/// The Keychain is used rather than a file or `UserDefaults` so the refresh token is protected
/// by the system at rest. No keychain sharing is requested and no access group is declared: the
/// item belongs to this app alone.
///
/// ## Why there are two keychains
///
/// macOS has two: the modern **data protection keychain** (`kSecUseDataProtectionKeychain`),
/// which is the one to prefer, and the older **file keychain** backed by the user's login
/// keychain.
///
/// The data protection keychain scopes every item to a *keychain access group*, and an app with
/// no `keychain-access-groups` entitlement falls back to its `com.apple.application-identifier`
/// entitlement for one. A macOS app whose only capabilities are App Sandbox and outgoing
/// network — which is exactly InboxSweep — is signed **without a provisioning profile**, so it
/// has neither entitlement, so it has no access group, so every data-protection write fails
/// with `errSecMissingEntitlement (-34018)`. That is not a bug in the save; it is the wrong
/// keychain for how this app is signed.
///
/// So the store consults both, in preference order, and uses the first one this process can
/// actually use. A build signed with a provisioning profile gets the data protection keychain;
/// a plain development build gets the file keychain. Neither is a downgrade chosen to make
/// something pass — the file keychain item is still owned by this app, still protected by the
/// login keychain, and still deleted on disconnect.
///
/// A store that cannot be used is skipped; a store that *refuses* is reported. Telling those
/// apart is the whole reason ``CredentialStoreError`` exists — the original defect was a write
/// that failed silently and a read that reported the absence as "no account".
nonisolated struct KeychainCredentialStore: GmailCredentialStoring {

    /// Which of the system's two keychains an operation addresses.
    ///
    /// Ordered by preference: ``dataProtection`` first, because it is app-scoped by the system
    /// rather than by an ACL, and only falls back when this process cannot use it.
    nonisolated enum Keychain: CaseIterable, Hashable, Sendable {

        /// The modern, access-group-scoped keychain. Needs an application-identifier or
        /// keychain-access-groups entitlement, which a profile-less development build lacks.
        case dataProtection

        /// The user's login keychain, reachable by any signed app for its own items.
        case file

        /// Most preferred first.
        static let inPreferenceOrder: [Keychain] = [.dataProtection, .file]

        var displayName: String {
            switch self {
            case .dataProtection: "data protection keychain"
            case .file: "login keychain"
            }
        }
    }

    private let service: String
    private let account: String
    private let keychains: [Keychain]

    /// - Parameters:
    ///   - service: The Keychain service name. One per logical store.
    ///   - account: The Keychain account key. Distinct values never see each other's items,
    ///     which is what keeps two stores — or two tests — from colliding.
    ///   - keychains: Which keychains to consult, most preferred first. Injectable so a test
    ///     can pin behaviour to one of them rather than depending on how the runner is signed.
    init(
        service: String = "InboxSweep.Gmail",
        account: String = "default",
        keychains: [Keychain] = Keychain.inPreferenceOrder
    ) {
        self.service = service
        self.account = account
        self.keychains = keychains
    }

    // MARK: - GmailCredentialStoring

    /// Returns the stored credentials, or `nil` when no keychain holds any.
    ///
    /// Throws only when a keychain *has* something and would not give it up, or when what it
    /// gave up was not a credential. "Nothing stored" is `nil`, never an error — but it is also
    /// never the answer given for a refusal, which is the bug this shape prevents.
    func load() throws -> GmailStoredCredentials? {
        var firstFailure: CredentialStoreError?

        for keychain in keychains {
            var query = baseQuery(for: keychain)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = KeychainStatus(SecItemCopyMatching(query as CFDictionary, &item))

            if status.rawValue == errSecSuccess {
                guard let data = item as? Data else {
                    throw try discardingMalformedItem(in: keychain)
                }
                do {
                    return try JSONDecoder().decode(GmailStoredCredentials.self, from: data)
                } catch {
                    // A stored blob this build can no longer read is useless, and leaving it
                    // there would make the app permanently unable to restore *or* to replace
                    // it. Drop it and report why, rather than looking like a first launch.
                    throw try discardingMalformedItem(in: keychain)
                }
            }

            if status.isNotFound || status.isKeychainUnavailable { continue }
            firstFailure = firstFailure ?? Self.error(for: status)
        }

        if let firstFailure { throw firstFailure }
        return nil
    }

    /// Writes `credentials`, replacing anything already stored.
    ///
    /// Writes to exactly one keychain — the most preferred usable one — and deletes any copy
    /// left in the others, so a build that gains the data protection keychain does not leave a
    /// stale refresh token behind in the login keychain.
    func save(_ credentials: GmailStoredCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        var lastUnavailable = KeychainStatus(errSecNotAvailable)

        for keychain in keychains {
            switch write(data, to: keychain) {
            case .written:
                for other in keychains where other != keychain {
                    _ = SecItemDelete(baseQuery(for: other) as CFDictionary)
                }
                return
            case .unavailable(let status):
                lastUnavailable = status
                continue
            case .failed(let error):
                throw error
            }
        }

        throw CredentialStoreError.noUsableKeychain(lastUnavailable)
    }

    /// Removes the stored credentials from every keychain consulted.
    func clear() throws {
        var firstFailure: CredentialStoreError?

        for keychain in keychains {
            let status = KeychainStatus(SecItemDelete(baseQuery(for: keychain) as CFDictionary))
            guard status.rawValue != errSecSuccess else { continue }
            if status.isNotFound || status.isKeychainUnavailable { continue }
            firstFailure = firstFailure ?? Self.error(for: status)
        }

        if let firstFailure { throw firstFailure }
    }

    // MARK: - Diagnostics

    /// Which keychain currently holds this store's item, if any.
    ///
    /// For the diagnostics surface only — it reports *where* a credential lives, never what it
    /// is. Returns `nil` when nothing is stored anywhere reachable.
    func storingKeychain() -> Keychain? {
        for keychain in keychains {
            var query = baseQuery(for: keychain)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess { return keychain }
        }
        return nil
    }

    // MARK: - Internals

    private enum WriteOutcome {
        case written
        /// This process cannot use this keychain; try the next one.
        case unavailable(KeychainStatus)
        case failed(CredentialStoreError)
    }

    private func write(_ data: Data, to keychain: Keychain) -> WriteOutcome {
        let query = baseQuery(for: keychain)

        let updateStatus = KeychainStatus(
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        )
        if updateStatus.rawValue == errSecSuccess { return .written }

        if updateStatus.isKeychainUnavailable { return .unavailable(updateStatus) }
        if !updateStatus.isNotFound { return .failed(Self.error(for: updateStatus)) }

        var insert = query
        insert[kSecValueData as String] = data
        // Names the item in Keychain Access, so a user who goes looking can see what it is
        // and delete it themselves. The lookup never matches on the label, so renaming it
        // here could not orphan an existing item.
        insert[kSecAttrLabel as String] = "InboxSweep — Gmail sign-in"
        if keychain == .dataProtection {
            // The refresh token is needed at launch without the user present, so it must
            // survive a reboot; it is never needed while the device is locked. This is the
            // narrowest class that satisfies both. `kSecAttrAccessible` is a data-protection
            // attribute and is not meaningful on the file keychain, so it is not set there.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }

        let addStatus = KeychainStatus(SecItemAdd(insert as CFDictionary, nil))
        if addStatus.rawValue == errSecSuccess { return .written }
        if addStatus.isKeychainUnavailable { return .unavailable(addStatus) }
        return .failed(Self.error(for: addStatus))
    }

    /// Deletes an unreadable item and returns the error to throw for it.
    ///
    /// Throwing rather than returning `nil` is deliberate: a caller told "nothing stored" would
    /// silently show a signed-out screen, and the user would never learn that their saved
    /// sign-in was discarded.
    private func discardingMalformedItem(in keychain: Keychain) throws -> CredentialStoreError {
        _ = SecItemDelete(baseQuery(for: keychain) as CFDictionary)
        return CredentialStoreError.malformedStoredData
    }

    private func baseQuery(for keychain: Keychain) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if keychain == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private static func error(for status: KeychainStatus) -> CredentialStoreError {
        if status.isAccessFailure { return .accessDenied(status) }
        if status.isDataFailure { return .malformedStoredData }
        return .unhandled(status)
    }
}

/// A store that keeps credentials only for the lifetime of the process.
///
/// Used by the tests, and as the provider's fallback when no keychain is usable at all, so
/// sign-in still works for the current session instead of failing outright. The user is asked
/// to connect again next launch — and, since this interval, actually told so.
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

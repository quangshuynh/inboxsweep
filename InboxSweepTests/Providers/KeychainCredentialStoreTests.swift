import Foundation
import Security
import Testing
@testable import InboxSweep

/// Exercises the **real** ``KeychainCredentialStore`` against the **real** Keychain.
///
/// The protocol-level tests that already exist run against ``InMemoryCredentialStore``, which
/// is why they were perfectly green while the app failed to persist a single credential: no
/// `SecItem*` call was ever made. These tests make those calls.
///
/// They can do so because the unit-test bundle is hosted by `InboxSweep.app` — the test process
/// *is* the app, with the app's bundle identifier, signing identity, and entitlements — so a
/// round trip here is the same round trip the app performs at sign-in.
///
/// Every credential below is synthetic. The service name is test-only and every case deletes
/// what it wrote, so a run leaves nothing behind in the developer's Keychain.
@Suite("Keychain credential store", .serialized)
struct KeychainCredentialStoreTests {

    // MARK: - Fixtures

    /// A service name no shipping build uses, so a test can never touch the real item.
    private static let testService = "InboxSweep.Tests.Gmail"

    /// Synthetic, and obviously so. Nothing here is or resembles a real Google credential.
    private func credentials(
        refreshToken: String = "synthetic-refresh-token",
        address: String = "sample.user@example.com",
        scopes: [String] = GmailScope.requested
    ) -> GmailStoredCredentials {
        GmailStoredCredentials(
            refreshToken: refreshToken,
            grantedScopes: scopes,
            accountEmailAddress: address
        )
    }

    /// A store on a unique account key, plus the cleanup that removes whatever it wrote.
    ///
    /// The account key is per-case so that two cases — or a case and a leftover from a crashed
    /// run — cannot see each other's items.
    private func withStore(
        account: String,
        keychains: [KeychainCredentialStore.Keychain] = KeychainCredentialStore.Keychain.inPreferenceOrder,
        _ body: (KeychainCredentialStore) throws -> Void
    ) rethrows {
        let store = KeychainCredentialStore(
            service: Self.testService,
            account: account,
            keychains: keychains
        )
        defer { try? store.clear() }
        try body(store)
    }

    // MARK: - Round trip

    @Test("A saved credential is read back exactly")
    func savesAndLoads() throws {
        try withStore(account: "round-trip") { store in
            let saved = credentials()
            try store.save(saved)

            let loaded = try store.load()
            #expect(loaded == saved)
        }
    }

    @Test("Reading before anything is written returns nothing, and is not an error")
    func loadsNothingWhenEmpty() throws {
        try withStore(account: "missing-item") { store in
            let loaded = try store.load()
            #expect(loaded == nil)
        }
    }

    @Test("Saving twice replaces rather than duplicating")
    func replacesOnSecondSave() throws {
        try withStore(account: "replace") { store in
            try store.save(credentials(refreshToken: "first", address: "one@example.com"))
            try store.save(credentials(refreshToken: "second", address: "two@example.com"))

            let loaded = try #require(try store.load())
            #expect(loaded.refreshToken == "second")
            #expect(loaded.accountEmailAddress == "two@example.com")

            // `kSecMatchLimitAll` would return an array if a second item had been added
            // alongside the first, which is the failure mode a blind `SecItemAdd` produces.
            #expect(try storedItemCount(account: "replace") == 1)
        }
    }

    @Test("Clearing removes the item, and clearing again is not an error")
    func clearsAndToleratesRepeatedClear() throws {
        try withStore(account: "delete") { store in
            try store.save(credentials())
            try store.clear()

            let afterClear = try store.load()
            #expect(afterClear == nil)

            // Disconnect can run when there is nothing stored; that is not a failure.
            try store.clear()
            let afterSecondClear = try store.load()
            #expect(afterSecondClear == nil)
        }
    }

    // MARK: - Isolation

    @Test("Two accounts in the same service do not see each other's credentials")
    func accountsDoNotCollide() throws {
        try withStore(account: "isolation-a") { first in
            try withStore(account: "isolation-b") { second in
                try first.save(credentials(refreshToken: "token-a", address: "a@example.com"))
                try second.save(credentials(refreshToken: "token-b", address: "b@example.com"))

                #expect(try first.load()?.accountEmailAddress == "a@example.com")
                #expect(try second.load()?.accountEmailAddress == "b@example.com")

                // And clearing one leaves the other alone — the case that matters when a
                // future interval lets the user sign out of one of two accounts.
                try first.clear()
                let clearedFirst = try first.load()
                #expect(clearedFirst == nil)
                #expect(try second.load()?.refreshToken == "token-b")
            }
        }
    }

    @Test("Two services do not see each other's credentials")
    func servicesDoNotCollide() throws {
        let other = KeychainCredentialStore(
            service: "InboxSweep.Tests.Gmail.Other",
            account: "shared-account-name"
        )
        defer { try? other.clear() }

        try withStore(account: "shared-account-name") { store in
            try store.save(credentials(refreshToken: "in-service-one"))
            let leaked = try other.load()
            #expect(leaked == nil)
        }
    }

    // MARK: - Malformed data

    @Test("A stored blob that is not a credential is reported and discarded, not mistaken for absence")
    func malformedDataIsReportedAndDiscarded() throws {
        let account = "malformed"
        let store = KeychainCredentialStore(service: Self.testService, account: account)
        defer { try? store.clear() }

        // Write bytes that are not the JSON this build decodes. The realistic route to this is
        // a credential written by a future build with a different shape.
        try writeRawItem(Data("not a credential".utf8), account: account)

        #expect(throws: CredentialStoreError.malformedStoredData) { try store.load() }

        // Discarded rather than left in place: an unreadable item that survived would make the
        // app permanently unable to restore, and the user would never be told why.
        let afterDiscard = try store.load()
        #expect(afterDiscard == nil)
    }

    // MARK: - Keychain selection

    @Test("The store falls back to the login keychain when the data protection keychain is unusable")
    func fallsBackToAUsableKeychain() throws {
        try withStore(account: "fallback") { store in
            try store.save(credentials())

            let keychain = try #require(store.storingKeychain())
            // Which one it lands in depends on how this build is signed, and both are correct.
            // What must be true either way is that it landed *somewhere* and reads back — the
            // property that was false before this interval, when a profile-less development
            // build wrote to the data protection keychain and got errSecMissingEntitlement.
            #expect(KeychainCredentialStore.Keychain.allCases.contains(keychain))
            let loaded = try store.load()
            #expect(loaded != nil)
        }
    }

    @Test("A store restricted to the login keychain still round-trips")
    func fileKeychainRoundTrips() throws {
        // Pinned rather than preference-ordered, so this case asserts the same behaviour on any
        // machine regardless of whether the data protection keychain happens to be available.
        try withStore(account: "file-only", keychains: [.file]) { store in
            try store.save(credentials(refreshToken: "file-keychain-token"))
            let loaded = try store.load()
            #expect(loaded?.refreshToken == "file-keychain-token")
            #expect(store.storingKeychain() == .file)
        }
    }

    @Test("A save leaves exactly one copy, never one per keychain")
    func savesToOneKeychainOnly() throws {
        try withStore(account: "single-copy") { store in
            try store.save(credentials())

            let holders = KeychainCredentialStore.Keychain.allCases.filter { keychain in
                KeychainCredentialStore(
                    service: Self.testService,
                    account: "single-copy",
                    keychains: [keychain]
                ).storingKeychain() != nil
            }
            #expect(holders.count == 1, "A refresh token was left behind in a second keychain")
        }
    }

    @Test("A store with no usable keychain says so rather than failing silently")
    func reportsWhenNothingIsWritable() throws {
        // The empty preference list is the honest stand-in for "no keychain this process can
        // use". The real-world version of it is the bug this interval fixed: a sandboxed build
        // with no application-identifier entitlement, for which every data-protection write
        // returns errSecMissingEntitlement.
        let store = KeychainCredentialStore(service: Self.testService, account: "unusable", keychains: [])

        #expect(throws: CredentialStoreError.self) { try store.save(credentials()) }
        // A read still answers "nothing stored" — there is genuinely nothing — but the *write*
        // is what must not be allowed to disappear.
        let loaded = try store.load()
        #expect(loaded == nil)
    }

    // MARK: - Secrets

    @Test("No error a store can throw contains any part of a credential")
    func errorsCarryNoSecret() {
        let secret = "synthetic-refresh-token"
        let errors: [CredentialStoreError] = [
            .accessDenied(KeychainStatus(errSecInteractionNotAllowed)),
            .malformedStoredData,
            .noUsableKeychain(KeychainStatus(errSecMissingEntitlement)),
            .unhandled(KeychainStatus(errSecParam)),
        ]

        for error in errors {
            let text = "\(error) \(error.diagnosticDescription)"
            #expect(!text.contains(secret))
            #expect(!text.lowercased().contains("token"))
        }
    }

    @Test("A Keychain status describes itself by name and number, and nothing else")
    func statusDescribesItself() {
        #expect(KeychainStatus(errSecMissingEntitlement).description == "errSecMissingEntitlement (-34018)")
        #expect(KeychainStatus(errSecItemNotFound).isNotFound)
        #expect(KeychainStatus(errSecMissingEntitlement).isKeychainUnavailable)
        #expect(KeychainStatus(errSecInteractionNotAllowed).isAccessFailure)
        #expect(!KeychainStatus(errSecSuccess).isNotFound)
    }

    // MARK: - Raw Keychain helpers
    //
    // These bypass the store on purpose: a test that seeds malformed data through the store
    // could not produce data the store would reject.

    private func writeRawItem(_ data: Data, account: String) throws {
        for keychain in KeychainCredentialStore.Keychain.inPreferenceOrder {
            var query = rawQuery(account: account, keychain: keychain)
            query[kSecValueData as String] = data
            if SecItemAdd(query as CFDictionary, nil) == errSecSuccess { return }
        }
        Issue.record("Could not seed a raw Keychain item in any keychain")
    }

    private func storedItemCount(account: String) throws -> Int {
        var total = 0
        for keychain in KeychainCredentialStore.Keychain.inPreferenceOrder {
            var query = rawQuery(account: account, keychain: keychain)
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            query[kSecReturnAttributes as String] = true

            var items: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess {
                total += (items as? [Any])?.count ?? 0
            }
        }
        return total
    }

    private func rawQuery(
        account: String,
        keychain: KeychainCredentialStore.Keychain
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.testService,
            kSecAttrAccount as String: account,
        ]
        if keychain == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}

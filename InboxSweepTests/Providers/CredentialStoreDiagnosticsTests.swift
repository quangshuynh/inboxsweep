import Foundation
import Security
import Testing
@testable import InboxSweep

/// What the app can honestly say about *which* Keychain it is using.
///
/// ``KeychainCredentialStoreTests`` covers whether a credential round-trips. These cover the
/// question that one cannot answer: a store that fell back to the login keychain and a store
/// that got the data protection keychain it asked for both report a successful save, and the
/// silence of that fallback is deliberate. Interval 5 exists because "which one did it use?"
/// had to be measured before any write-capable scope is added, and these are the cases that
/// keep the measurement honest.
///
/// Every credential below is synthetic and lives under diagnostic-only service names. The
/// probes delete what they write; the closing case asserts they did.
@Suite("Credential store diagnostics", .serialized)
struct CredentialStoreDiagnosticsTests {

    // MARK: - Probing

    @Test("A probe of the login keychain completes a full save, replace and delete round trip")
    func loginKeychainProbeRoundTrips() {
        // Pinned to the one keychain available to any signed build, so this case asserts the
        // same thing regardless of how the test runner happens to be provisioned.
        let probe = CredentialStoreDiagnostics.probe(.file)

        #expect(probe.keychain == .file)
        #expect(probe.outcome == .roundTripped)
        #expect(probe.isUsable)
    }

    @Test("A probe answers for the keychain it was asked about, never by falling back to another")
    func probeNeverFallsBack() {
        // On a build with no application-identifier entitlement this is `.unavailable`; on a
        // provisioned one it is `.roundTripped`. What must never happen is the answer arriving
        // from the *other* keychain, which is exactly what the production store would do and
        // what would make a verification result meaningless.
        let probe = CredentialStoreDiagnostics.probe(.dataProtection)

        #expect(probe.keychain == .dataProtection)
        switch probe.outcome {
        case .roundTripped, .unavailable:
            break
        case .failed(let step, let reason):
            Issue.record("The data protection keychain was reachable and misbehaved at \(step): \(reason)")
        }
    }

    @Test("The backend a probe names is the one the production store actually writes to")
    func probedBackendMatchesTheProductionStore() throws {
        // The cross-check that makes the diagnostic worth trusting: the probe pins keychains
        // and the real store falls back between them, so the two agreeing is evidence that the
        // probe describes the app rather than describing itself.
        let probes = CredentialStoreDiagnostics.probeAll()
        let preferred = try #require(CredentialStoreDiagnostics.preferredUsableKeychain(probes))

        let store = KeychainCredentialStore(
            service: "InboxSweep.Tests.Diagnostics",
            account: "backend-agreement"
        )
        defer { try? store.clear() }

        try store.save(
            GmailStoredCredentials(
                refreshToken: "synthetic-refresh-token",
                grantedScopes: GmailScope.requested,
                accountEmailAddress: "sample.user@example.com"
            )
        )

        #expect(store.storingKeychain() == preferred)
    }

    @Test("Probing leaves nothing behind in any keychain")
    func probeCleansUpAfterItself() {
        _ = CredentialStoreDiagnostics.probeAll()

        for keychain in KeychainCredentialStore.Keychain.allCases {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: CredentialStoreDiagnostics.probeService,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            if keychain == .dataProtection {
                query[kSecUseDataProtectionKeychain as String] = true
            }
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            #expect(status == errSecItemNotFound, "A probe left an item in the \(keychain.displayName)")
        }
    }

    // MARK: - Reporting

    @Test("The storage description names the backend, and says so plainly when there is none")
    func describesWhereCredentialsLive() {
        #expect(
            CredentialStoreDiagnostics.storageDescription(for: .dataProtection)
                == "Credential storage: Data Protection Keychain"
        )
        #expect(
            CredentialStoreDiagnostics.storageDescription(for: .file)
                == "Credential storage: Login Keychain fallback"
        )
        #expect(
            CredentialStoreDiagnostics.storageDescription(for: nil)
                == "Credential storage: nothing stored"
        )
    }

    @Test("A probe report lists every keychain, including the ones that refused")
    func reportCoversEveryKeychain() {
        let probes: [CredentialStoreProbe] = [
            CredentialStoreProbe(
                keychain: .dataProtection,
                outcome: .unavailable(KeychainStatus(errSecMissingEntitlement))
            ),
            CredentialStoreProbe(keychain: .file, outcome: .roundTripped),
        ]

        let report = CredentialStoreSelfCheck.probeReport(probes: probes)

        #expect(report.contains("data protection keychain: unavailable (errSecMissingEntitlement (-34018))"))
        #expect(report.contains("login keychain: round-tripped"))
        // The point of the line: a reader must not have to work out which one won.
        #expect(report.contains("preferred=login keychain"))
        #expect(report.contains("Credential storage: Login Keychain fallback"))
    }

    @Test("A report for a build where no keychain works says so rather than naming one anyway")
    func reportsWhenNoKeychainIsUsable() {
        let probes: [CredentialStoreProbe] = [
            CredentialStoreProbe(
                keychain: .dataProtection,
                outcome: .unavailable(KeychainStatus(errSecMissingEntitlement))
            ),
            CredentialStoreProbe(
                keychain: .file,
                outcome: .failed(step: .save, reason: "The Keychain reported errSecAuthFailed (-25293).")
            ),
        ]

        let report = CredentialStoreSelfCheck.probeReport(probes: probes)

        #expect(report.contains("preferred=none"))
        #expect(report.contains("Credential storage: nothing stored"))
        #expect(CredentialStoreDiagnostics.preferredUsableKeychain(probes) == nil)
    }

    @Test("The backend report states where the real credential is without reading it")
    func backendReportNamesTheBackend() {
        #expect(
            CredentialStoreSelfCheck.backendReport(backend: .file)
                == "BACKEND Credential storage: Login Keychain fallback"
        )
        #expect(
            CredentialStoreSelfCheck.backendReport(backend: nil)
                == "BACKEND Credential storage: nothing stored"
        )
    }

    // MARK: - Secrets

    @Test("Nothing a probe or a report can print resembles a credential")
    func diagnosticsCarryNoSecret() {
        var text = CredentialStoreSelfCheck.probeReport()
        text += "\n" + CredentialStoreSelfCheck.backendReport()
        for keychain in KeychainCredentialStore.Keychain.allCases {
            text += "\n" + CredentialStoreDiagnostics.probe(keychain).summary
        }

        // The probe's synthetic marker says in its own text that it is not a credential, and
        // even that must not reach a diagnostic line.
        #expect(!text.contains("not-a-credential"))
        #expect(!text.lowercased().contains("token"))
        #expect(!text.lowercased().contains("secret"))
        #expect(!text.lowercased().contains("refresh"))
    }
}

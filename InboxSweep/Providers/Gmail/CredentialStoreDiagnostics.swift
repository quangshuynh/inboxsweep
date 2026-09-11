import Foundation
import Security

/// What one keychain did when a credential was round-tripped through it, with no fallback.
///
/// The point of pinning is that a result is unambiguous. ``KeychainCredentialStore`` is built
/// to *skip* a keychain this process cannot use and quietly succeed on the next one, which is
/// the right behaviour in production and exactly the wrong behaviour when the question being
/// asked is "which keychain is this build actually using?". A probe answers per keychain, so
/// nothing it reports was produced by a fallback.
nonisolated struct CredentialStoreProbe: Equatable, Sendable {

    /// The operations a probe performs, in order. Named so a failure says which one.
    enum Step: String, Equatable, Sendable, CaseIterable {
        case save
        case load
        case replace
        case reload
        case delete
        case confirmDeleted
    }

    enum Outcome: Equatable, Sendable {
        /// Save, load, replace, delete and a confirming read all did what they claim.
        case roundTripped

        /// This process cannot use this keychain at all, and the status says why. The usual
        /// one is `errSecMissingEntitlement (-34018)` on the data protection keychain for a
        /// build signed without a provisioning profile.
        case unavailable(KeychainStatus)

        /// The keychain is reachable, and a step did not do what it said it did.
        case failed(step: Step, reason: String)
    }

    let keychain: KeychainCredentialStore.Keychain
    let outcome: Outcome

    /// Whether this keychain can hold a credential for this build.
    var isUsable: Bool { outcome == .roundTripped }

    /// One line, safe to print. Carries a keychain name, a step name, and at most an
    /// `OSStatus`; there is nothing in it derived from a credential.
    var summary: String {
        switch outcome {
        case .roundTripped:
            "\(keychain.displayName): round-tripped"
        case .unavailable(let status):
            "\(keychain.displayName): unavailable (\(status))"
        case .failed(let step, let reason):
            "\(keychain.displayName): failed at \(step.rawValue), \(reason)"
        }
    }
}

/// Answers, for the build that is running, which Keychain backend the app's credentials use.
///
/// It exists because that question could previously only be answered by reasoning about
/// entitlements. A build signed one way uses the data protection keychain and a build signed
/// another way falls back to the login keychain, the two are indistinguishable from the
/// outside, and the fallback is deliberately silent, so "which one did it use?" needs
/// measuring rather than deducing.
///
/// Nothing here reads, prints, or returns a credential. ``probe(_:)`` writes a synthetic marker
/// under a service no shipping path uses and deletes it again; ``storageBackend()`` asks only
/// whether an item *exists*, never for its bytes.
nonisolated enum CredentialStoreDiagnostics {

    /// A service name no shipping code path writes to, so a probe can never disturb a sign-in.
    static let probeService = "InboxSweep.Diagnostics.Probe"

    // MARK: - Probing

    /// Round-trips a synthetic credential through `keychain` and reports exactly what happened.
    ///
    /// The store under test is the production ``KeychainCredentialStore`` (the same type, the
    /// same `SecItem*` calls, the same encoding) pinned to one keychain so a skip becomes a
    /// reported `.unavailable` instead of a silent hop to the next one.
    static func probe(_ keychain: KeychainCredentialStore.Keychain) -> CredentialStoreProbe {
        // Per-probe account key: two probes, or a probe and the wreckage of a crashed one,
        // must not see each other's items.
        let store = KeychainCredentialStore(
            service: probeService,
            account: "probe-\(UUID().uuidString)",
            keychains: [keychain]
        )

        func probe(_ outcome: CredentialStoreProbe.Outcome) -> CredentialStoreProbe {
            CredentialStoreProbe(keychain: keychain, outcome: outcome)
        }

        func failure(_ step: CredentialStoreProbe.Step, _ error: any Error) -> CredentialStoreProbe {
            let reason = (error as? CredentialStoreError)?.diagnosticDescription
                ?? "The Keychain reported an error this build does not name."
            return probe(.failed(step: step, reason: reason))
        }

        let first = marker(tag: "first")
        do {
            try store.save(first)
        } catch CredentialStoreError.noUsableKeychain(let status) {
            // The one outcome that is not a fault: this process cannot use this keychain.
            return probe(.unavailable(status))
        } catch {
            return failure(.save, error)
        }

        // From here on the item exists, so every exit has to remove it.
        defer { try? store.clear() }

        do {
            guard try store.load() == first else {
                return probe(.failed(step: .load, reason: "The Keychain returned something other than what was written."))
            }
        } catch {
            return failure(.load, error)
        }

        let second = marker(tag: "second")
        do {
            try store.save(second)
        } catch {
            return failure(.replace, error)
        }

        do {
            guard try store.load() == second else {
                return probe(.failed(step: .reload, reason: "A replacement was written and the previous value was read back."))
            }
            guard store.storingKeychain() == keychain else {
                return probe(.failed(step: .reload, reason: "The item was not found in the keychain it was written to."))
            }
        } catch {
            return failure(.reload, error)
        }

        do {
            try store.clear()
        } catch {
            return failure(.delete, error)
        }

        do {
            guard try store.load() == nil else {
                return probe(.failed(step: .confirmDeleted, reason: "A deleted credential was still readable."))
            }
        } catch {
            return failure(.confirmDeleted, error)
        }

        return probe(.roundTripped)
    }

    /// Probes every keychain, most preferred first.
    static func probeAll(
        _ keychains: [KeychainCredentialStore.Keychain] = KeychainCredentialStore.Keychain.inPreferenceOrder
    ) -> [CredentialStoreProbe] {
        keychains.map(probe)
    }

    /// The keychain a save would land in for this build, or `nil` when none is usable.
    ///
    /// Derived from probes rather than from entitlements, so it reports what the system does
    /// rather than what the build settings suggest it ought to.
    static func preferredUsableKeychain(
        _ probes: [CredentialStoreProbe] = probeAll()
    ) -> KeychainCredentialStore.Keychain? {
        probes.first(where: \.isUsable)?.keychain
    }

    // MARK: - Where the real credential lives

    /// Which keychain currently holds the app's stored Gmail credential, if any.
    ///
    /// Existence only. The item's data is never requested, so this cannot return, log, or leak
    /// a refresh token even by accident.
    static func storageBackend(
        store: KeychainCredentialStore = KeychainCredentialStore()
    ) -> KeychainCredentialStore.Keychain? {
        store.storingKeychain()
    }

    /// The developer-facing sentence for where a credential is stored.
    ///
    /// `Credential storage: Data Protection Keychain`, `Credential storage: Login Keychain
    /// fallback`, or a statement that there is nothing stored.
    static func storageDescription(for keychain: KeychainCredentialStore.Keychain?) -> String {
        guard let keychain else { return "Credential storage: nothing stored" }
        return "Credential storage: \(keychain.diagnosticLabel)"
    }

    // MARK: - Internals

    /// Synthetic, and recognisably so. The "refresh token" is a fixed literal that says what it
    /// is, and the address is in a reserved domain.
    private static func marker(tag: String) -> GmailStoredCredentials {
        GmailStoredCredentials(
            refreshToken: "credential-store-probe-\(tag)-not-a-credential",
            grantedScopes: GmailScope.requested,
            accountEmailAddress: "probe-\(tag)@example.com"
        )
    }
}

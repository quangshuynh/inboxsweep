import Foundation

/// A launch-argument check that answers, about *the binary that is running*, three questions
/// that cannot be answered any other way:
///
/// 1. Does a credential written by this app survive being quit and reopened?
/// 2. Which of the system's two keychains does this build actually get?
/// 3. Where is the app's real Gmail credential stored right now?
///
/// The first cannot be answered by the unit tests. They run inside the app process and prove
/// the `SecItem*` calls work, but they run inside *one* process; only a real quit and a real
/// relaunch proves persistence, and only running the same `.app` twice (versus rebuilding in
/// between) tells a same-binary relaunch apart from a re-sign.
///
/// The second cannot be answered by ``KeychainCredentialStore`` in normal use, because its
/// fallback is deliberately silent. ``CredentialStoreDiagnostics`` pins each keychain so the
/// answer is measured rather than inferred from entitlements.
///
/// ## Why this is compiled into every configuration
///
/// It used to be `#if DEBUG`. That made the one build whose behaviour matters most, the
/// signed Release app the user actually launches, the one build that could not be asked. A
/// Debug and a Release build of this app are signed with the same identity and carry the same
/// entitlements, so the answers *ought* to match; "ought to" is the kind of claim this whole
/// area of the app exists to stop making.
///
/// It stays safe to ship because of what it is, not where it is compiled: every mode is inert
/// unless an explicit launch argument is passed, no UI reaches any of them, the round trip and
/// the probes write synthetic markers under their own Keychain services, and the one mode that
/// touches the real item asks only whether it *exists*. No output below can contain an access
/// token, a refresh token, an authorization code, or a client secret.
nonisolated enum CredentialStoreSelfCheck {

    /// Writes a synthetic marker, or reports the one an earlier launch wrote.
    static let launchArgument = "--keychain-selfcheck"

    /// Removes the marker written by ``launchArgument``.
    static let resetArgument = "--keychain-selfcheck-reset"

    /// Round-trips a synthetic credential through each keychain separately, with no fallback.
    static let probeArgument = "--keychain-probe"

    /// Reports which keychain holds the app's real Gmail credential, without reading it.
    static let backendArgument = "--keychain-backend"

    /// A service name the shipping store never uses.
    private static let service = "InboxSweep.SelfCheck"

    /// Runs whichever check was asked for, and never returns when one runs.
    ///
    /// Called before any window is created, so a check costs one process launch rather than a
    /// whole app session.
    static func runIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        if arguments.contains(resetArgument) {
            try? KeychainCredentialStore(service: service, account: "marker").clear()
            print("SELFCHECK reset")
            exit(0)
        }

        if arguments.contains(probeArgument) {
            print(probeReport())
            exit(0)
        }

        if arguments.contains(backendArgument) {
            print(backendReport())
            exit(0)
        }

        guard arguments.contains(launchArgument) else { return }
        print(report())
        exit(0)
    }

    // MARK: - Cross-launch persistence

    /// One line, machine-readable, carrying no secret.
    ///
    /// Reports which keychain the item landed in, because that is the fact the original defect
    /// turned on, and a build that silently changed keychains would otherwise look identical.
    static func report() -> String {
        let store = KeychainCredentialStore(service: service, account: "marker")

        do {
            if let existing = try store.load() {
                let keychain = store.storingKeychain()?.displayName ?? "unknown"
                return "SELFCHECK restored keychain=\(keychain) written_at=\(existing.accountEmailAddress)"
            }
        } catch {
            let reason = (error as? CredentialStoreError)?.diagnosticDescription ?? "unreadable"
            return "SELFCHECK unreadable reason=\(reason)"
        }

        // Synthetic throughout. The "refresh token" is a fixed literal and the "address" is a
        // timestamp in a reserved domain, so a stored marker says when it was written without
        // any of this resembling a credential.
        let marker = GmailStoredCredentials(
            refreshToken: "self-check-marker-not-a-credential",
            grantedScopes: GmailScope.requested,
            accountEmailAddress: "\(Int(Date().timeIntervalSince1970))@example.com"
        )

        do {
            try store.save(marker)
            let keychain = store.storingKeychain()?.displayName ?? "unknown"
            return "SELFCHECK stored keychain=\(keychain)"
        } catch {
            let reason = (error as? CredentialStoreError)?.diagnosticDescription ?? "unwritable"
            return "SELFCHECK unwritable reason=\(reason)"
        }
    }

    // MARK: - Which keychain this build gets

    /// One `PROBE` line per keychain, then the one a save would use.
    ///
    /// Every keychain is reported, including the ones that refused, which is the difference
    /// between this and watching a credential succeed: a store that fell back looks exactly
    /// like a store that got what it wanted.
    static func probeReport(
        probes: [CredentialStoreProbe] = CredentialStoreDiagnostics.probeAll()
    ) -> String {
        var lines = probes.map { "PROBE \($0.summary)" }
        let preferred = CredentialStoreDiagnostics.preferredUsableKeychain(probes)
        lines.append("PROBE preferred=\(preferred?.displayName ?? "none")")
        lines.append("PROBE \(CredentialStoreDiagnostics.storageDescription(for: preferred))")
        return lines.joined(separator: "\n")
    }

    // MARK: - Where the real credential lives

    /// Where the app's stored Gmail credential is, by existence check alone.
    static func backendReport(
        backend: KeychainCredentialStore.Keychain? = CredentialStoreDiagnostics.storageBackend()
    ) -> String {
        "BACKEND \(CredentialStoreDiagnostics.storageDescription(for: backend))"
    }
}

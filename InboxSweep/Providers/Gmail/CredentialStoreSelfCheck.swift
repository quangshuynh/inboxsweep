#if DEBUG
import Foundation

/// A debug-only check that answers one question honestly: **does a credential written by this
/// app survive being quit and reopened?**
///
/// It exists because that question cannot otherwise be answered without a Google password. The
/// unit tests run inside the app process and prove the `SecItem*` calls work, but they run
/// inside *one* process; only a real quit and a real relaunch proves persistence, and only
/// running the same `.app` twice — versus rebuilding in between — tells a same-binary relaunch
/// apart from a development re-sign.
///
/// So the app takes a launch argument that writes a synthetic marker, reports what it found,
/// and exits. Run it twice against one build and the second run says `restored`. Rebuild and
/// run again, and it says whether re-signing changed the answer. See `Docs/SessionRestore.md`
/// for the recorded results.
///
/// The marker is synthetic, lives under its own Keychain service so it can never collide with
/// the real sign-in, and `--keychain-selfcheck-reset` removes it. Debug builds only: this is
/// not compiled into a release build, and there is no UI that reaches it.
nonisolated enum CredentialStoreSelfCheck {

    static let launchArgument = "--keychain-selfcheck"
    static let resetArgument = "--keychain-selfcheck-reset"

    /// A service name the shipping store never uses.
    private static let service = "InboxSweep.SelfCheck"

    /// Runs the check if asked to, and never returns when it does.
    ///
    /// Called before any window is created, so the check costs one process launch rather than
    /// a whole app session.
    static func runIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        if arguments.contains(resetArgument) {
            try? KeychainCredentialStore(service: service, account: "marker").clear()
            print("SELFCHECK reset")
            exit(0)
        }

        guard arguments.contains(launchArgument) else { return }
        print(report())
        exit(0)
    }

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
}
#endif

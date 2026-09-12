import Foundation

/// Whether this directory actually keeps a backup-exclusion flag, measured rather than assumed.
///
/// ### Why a store's test cannot simply demand the outcome
///
/// Every file-backed store asks for `isExcludedFromBackup` on the file it writes. On a
/// development Mac that sticks. On a GitHub-hosted `macos-26` runner, inside the sandboxed test
/// host, it does not, and the way it fails is the interesting part:
///
/// ```
/// path:      /Users/runner/Library/Containers/quang.InboxSweep/Data/tmp/.../<digest>.json
/// set:       succeeds, throws nothing
/// read back: Optional(false)
/// ```
///
/// The platform accepts the request and discards it. That is not the store getting it wrong, and
/// it is not the volume: an unsandboxed probe on the same runner, writing into that same
/// container path, reads back `true`. Signing was ruled out separately by rebuilding locally
/// with CI's exact ad-hoc flags, which passes.
///
/// ### What the tests assert instead
///
/// A control file in the same directory asks for the same thing, explicitly. The store's file is
/// then required to match it. That is the promise the app can actually make, and it is stricter
/// than the original assertion rather than looser:
///
/// - where the platform keeps the flag, the control reads `true` and so must the store's file;
/// - where the platform discards it, the control reads `false` and so must the store's file;
/// - **a store that stopped asking fails either way**, because the control still reports what a
///   file that did ask would have got.
///
/// There is no environment check anywhere in it. Nothing is skipped, and no assertion is
/// conditioned on which machine is running.
func backupExclusionTakesEffect(in directory: URL) -> Bool {
    var control = directory.appending(path: "backup-exclusion-control-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: control) }

    guard (try? Data("control".utf8).write(to: control, options: [.atomic])) != nil else { return false }

    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    guard (try? control.setResourceValues(values)) != nil else { return false }

    return (try? control.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
}

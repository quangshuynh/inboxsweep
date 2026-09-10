import CryptoKit
import Foundation

/// Stores one account's loaded window as a JSON file inside the app's own container.
///
/// An actor, so a save that overlaps a load or another save is serialized rather than racing
/// on the same file. Every operation is best-effort: nothing here throws, because a cache that
/// cannot be read is a refetch and a cache that cannot be written is a refetch next launch —
/// neither is a failure the user needs to hear about.
///
/// ### What ends up on disk
///
/// Message metadata: sender, subject, date, labels, and whether a `List-Unsubscribe` header
/// was present. No message body, because ``MailMessage`` has nowhere to hold one. No token of
/// any kind — the refresh token stays in the Keychain and access tokens are never persisted at
/// all.
///
/// The file lives in the sandboxed container's Application Support directory, is written with
/// owner-only permissions, and is excluded from backups. Disconnecting deletes it.
actor FileInboxCacheStore: InboxCacheStoring {

    /// The container-relative directory the cache file lives in.
    static let directoryName = "InboxSweep/Cache"

    private let directory: URL?
    private let fileManager: FileManager

    /// Creates a store rooted at the app's Application Support directory.
    ///
    /// `directory` is injectable so tests can exercise the real file paths in a temporary
    /// location rather than in the developer's own container.
    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL? {
        // A missing Application Support directory would be extraordinary, but it is not worth
        // trapping over: the app simply runs without a cache.
        try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: directoryName)
    }

    // MARK: - InboxCacheStoring

    func load(for account: MailAccount) async -> CachedInbox? {
        guard let url = fileURL(for: account),
              let data = try? Data(contentsOf: url),
              let record = try? InboxCacheDTO.makeDecoder().decode(InboxCacheDTO.Record.self, from: data),
              let inbox = InboxCacheDTO.inbox(from: record)
        else { return nil }

        // The filename is derived from the address, so a mismatch here means a hash collision
        // or a hand-edited file. Either way it is not this account's mail.
        guard inbox.account.emailAddress.address == account.emailAddress.address else { return nil }

        return inbox
    }

    func save(_ inbox: CachedInbox) async {
        guard let directory, let url = fileURL(for: inbox.account) else { return }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try InboxCacheDTO.makeEncoder().encode(InboxCacheDTO.record(from: inbox))
            try data.write(to: url, options: [.atomic])
            try restrictToOwner(url)
            excludeFromBackup(url)
            discardFiles(otherThan: url, in: directory)
        } catch {
            // Nothing to recover: the window is still in memory, and the next save will try
            // again. Surfacing this would be an error about a feature the user did not ask for.
            return
        }
    }

    func clear(for account: MailAccount) async {
        guard let url = fileURL(for: account) else { return }
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Internals

    /// One file per account, named by a digest of the address.
    ///
    /// Hashed rather than written plainly so the address a user signed in with is not legible
    /// from a directory listing alone.
    private func fileURL(for account: MailAccount) -> URL? {
        guard let directory else { return nil }
        let address = account.emailAddress.address.lowercased()
        let digest = SHA256.hash(data: Data(address.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: "\(digest.prefix(32)).json")
    }

    private func restrictToOwner(_ url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Keeps exactly one account's window on disk.
    ///
    /// Signing into a second account must not leave the first account's metadata behind, and
    /// nothing in the app would ever read those files again.
    private func discardFiles(otherThan keep: URL, in directory: URL) {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        for url in contents where url.lastPathComponent != keep.lastPathComponent {
            guard url.pathExtension == "json" else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}

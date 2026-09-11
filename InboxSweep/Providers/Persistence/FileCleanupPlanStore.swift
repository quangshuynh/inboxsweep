import CryptoKit
import Foundation

/// Stores one account's preview selections as a JSON file inside the app's own container.
///
/// An actor, so a save that overlaps a load is serialized rather than racing on the same file.
/// Every operation is best-effort: nothing here throws, because a plan that cannot be read
/// means the user picks their senders again.
///
/// ### What ends up on disk
///
/// Sender grouping keys and chosen action identifiers. **No mail.** No subjects, no dates, no
/// counts of what would be affected, no proposal, no reason, no protection verdict — all of
/// that is derived from the loaded window and recomputed on every launch. A plan file cannot
/// contain message metadata, because ``SavedCleanupPlan`` has nowhere to put any.
///
/// A sender grouping key *is* an email address, so the file is written with the same care the
/// mailbox cache is: owner-only permissions, inside the sandboxed container, excluded from
/// backups, and deleted on disconnect.
actor FileCleanupPlanStore: CleanupPlanStoring {

    /// The container-relative directory the plan file lives in.
    static let directoryName = "InboxSweep/Plans"

    private let directory: URL?
    private let fileManager: FileManager

    /// `directory` is injectable so tests can exercise the real file paths in a temporary
    /// location rather than in the developer's own container.
    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL? {
        try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: directoryName)
    }

    // MARK: - CleanupPlanStoring

    func load(for account: MailAccount) async -> SavedCleanupPlan? {
        guard let url = fileURL(for: account),
              let data = try? Data(contentsOf: url),
              let record = try? CleanupPlanDTO.makeDecoder().decode(CleanupPlanDTO.Record.self, from: data),
              let plan = CleanupPlanDTO.plan(from: record)
        else { return nil }

        // The filename is derived from the address, so a mismatch here means a hash collision
        // or a hand-edited file. Either way these are not this account's choices, and applying
        // one account's sender selections to another's mailbox is exactly the confusion the
        // account check exists to prevent.
        guard plan.belongs(to: account) else { return nil }

        return plan
    }

    func save(_ plan: SavedCleanupPlan) async {
        guard let directory,
              let url = fileURL(forAddress: plan.accountAddress)
        else { return }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try CleanupPlanDTO.makeEncoder().encode(CleanupPlanDTO.record(from: plan))
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path(percentEncoded: false)
            )
            excludeFromBackup(url)
            discardFiles(otherThan: url, in: directory)
        } catch {
            // Nothing to recover: the selections are still on screen, and the next save will
            // try again. Surfacing this would be an error about a convenience.
            return
        }
    }

    func clear(for account: MailAccount) async {
        guard let url = fileURL(for: account) else { return }
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Internals

    private func fileURL(for account: MailAccount) -> URL? {
        fileURL(forAddress: account.emailAddress.address)
    }

    /// One file per account, named by a digest of the address, so the address a user signed in
    /// with is not legible from a directory listing alone.
    private func fileURL(forAddress address: String) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(address.lowercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: "\(digest.prefix(32)).json")
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Keeps exactly one account's plan on disk.
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

/// The on-disk shape of a saved plan.
///
/// Every key is written out explicitly and actions are stored by their stable identifier rather
/// than by anything `Codable` would synthesize for an enum with associated values, so renaming
/// a Swift case cannot silently invalidate somebody's saved choices — or, worse, decode into a
/// different action than the one they picked.
nonisolated enum CleanupPlanDTO {

    /// Bumped whenever the shape below changes incompatibly. A file written by any other
    /// version is discarded rather than guessed at.
    static let schemaVersion = 1

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    struct Record: Codable, Equatable {
        var version: Int
        var accountAddress: String
        var scope: String
        var rulesVersion: Int
        var loadedMessageCount: Int
        var savedAt: Date
        var selections: [Selection]

        enum CodingKeys: String, CodingKey {
            case version = "v"
            case accountAddress = "account"
            case scope
            case rulesVersion = "rules_version"
            case loadedMessageCount = "loaded_messages"
            case savedAt = "saved_at"
            case selections
        }
    }

    struct Selection: Codable, Equatable {
        var senderKey: String
        var actionID: String

        enum CodingKeys: String, CodingKey {
            case senderKey = "sender"
            case actionID = "action"
        }
    }

    static func record(from plan: SavedCleanupPlan) -> Record {
        Record(
            version: schemaVersion,
            accountAddress: plan.accountAddress,
            scope: plan.scope.rawValue,
            rulesVersion: plan.rulesVersion,
            loadedMessageCount: plan.loadedMessageCount,
            savedAt: plan.savedAt,
            selections: plan.selections.map {
                Selection(senderKey: $0.senderKey, actionID: $0.action.id)
            }
        )
    }

    /// Rebuilds a plan, or returns `nil` when the record is not one this build can use.
    ///
    /// An unrecognised action drops that one selection rather than the whole plan: a file
    /// written by a version offering a cutoff this build does not is still mostly usable, and
    /// the restored plan reports the senders that went missing.
    static func plan(from record: Record) -> SavedCleanupPlan? {
        guard record.version == schemaVersion,
              let scope = MailboxScope(rawValue: record.scope)
        else { return nil }

        return SavedCleanupPlan(
            accountAddress: record.accountAddress,
            scope: scope,
            selections: record.selections.compactMap { selection in
                PlannedCleanupAction(id: selection.actionID).map {
                    SavedCleanupSelection(senderKey: selection.senderKey, action: $0)
                }
            },
            rulesVersion: record.rulesVersion,
            loadedMessageCount: record.loadedMessageCount,
            savedAt: record.savedAt
        )
    }
}

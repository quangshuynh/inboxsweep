import CryptoKit
import Foundation

/// Stores one account's mutation records as a JSON file inside the app's own container.
///
/// Follows the mailbox cache and the plan store exactly: an actor so overlapping writes are
/// serialized, one file per account named by a digest of the address, owner-only permissions,
/// excluded from backups, and every other account's file removed on save.
///
/// ### What ends up on disk
///
/// A provider message identifier, an account address, an operation name, a timestamp, and
/// whether Gmail confirmed it. **No mail.** No subject, no sender, no body — ``MailMutationRecord``
/// has nowhere to put any of them.
///
/// Unlike the cache, this one *reports* whether a write succeeded. A cache that cannot be
/// written costs a refetch; a mutation record that cannot be written means the app has changed
/// a mailbox and failed to write that down, which the user is told about rather than left to
/// discover.
actor FileMutationRecordStore: MailMutationRecording {

    /// The container-relative directory the record file lives in.
    static let directoryName = "InboxSweep/Mutations"

    /// How many of the most recent records are kept.
    ///
    /// Bounded because this is a receipt drawer, not a log: the app performs one mutation per
    /// deliberate user action, and a file that grew without limit would be the first thing in
    /// InboxSweep that accumulated a history of someone's mailbox.
    static let retainedRecordLimit = 50

    private let directory: URL?
    private let fileManager: FileManager

    /// `directory` is injectable so tests exercise the real file paths in a temporary location
    /// rather than in the developer's own container.
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

    // MARK: - MailMutationRecording

    func record(_ record: MailMutationRecord) async -> MutationRecordOutcome {
        guard let directory, let url = fileURL(forAccountAddress: record.accountAddress) else {
            return .notStored(reason: "InboxSweep couldn't find a place on this Mac to write the record.")
        }

        var records = loadRecords(from: url).filter { $0.id != record.id }
        records.append(record)
        records.sort { $0.occurredAt > $1.occurredAt }
        records = Array(records.prefix(Self.retainedRecordLimit))

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = MutationRecordDTO.File(
                version: MutationRecordDTO.schemaVersion,
                accountAddress: record.accountAddress,
                records: records.map(MutationRecordDTO.entry(from:))
            )
            let data = try MutationRecordDTO.makeEncoder().encode(file)
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path(percentEncoded: false)
            )
            excludeFromBackup(url)
            discardFiles(otherThan: url, in: directory)
            return .stored
        } catch {
            // Deliberately not the error's own description: a file-system error can name a
            // path, and the path names the account's digest.
            return .notStored(reason: "InboxSweep couldn't write the record to this Mac.")
        }
    }

    func records(for account: MailAccount) async -> [MailMutationRecord] {
        guard let url = fileURL(forAccountAddress: account.emailAddress.address) else { return [] }
        return loadRecords(from: url)
            .filter { $0.accountAddress == account.emailAddress.address }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    func clear(for account: MailAccount) async {
        guard let url = fileURL(forAccountAddress: account.emailAddress.address) else { return }
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Internals

    /// Reads what is on disk, or nothing at all.
    ///
    /// Non-throwing in both directions a read can go wrong: a file this build does not
    /// recognise, and a file written for a different account. Neither is worth an error — the
    /// worst case is that an undo is not offered.
    private func loadRecords(from url: URL) -> [MailMutationRecord] {
        guard let data = try? Data(contentsOf: url),
              let file = try? MutationRecordDTO.makeDecoder().decode(MutationRecordDTO.File.self, from: data),
              file.version == MutationRecordDTO.schemaVersion
        else { return [] }

        return file.records.compactMap { MutationRecordDTO.record(from: $0, accountAddress: file.accountAddress) }
    }

    /// One file per account, named by a digest of the address, so the address a user signed in
    /// with is not legible from a directory listing alone.
    private func fileURL(forAccountAddress address: String) -> URL? {
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

    /// Keeps exactly one account's records on disk.
    private func discardFiles(otherThan keep: URL, in directory: URL) {
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent != keep.lastPathComponent {
            guard url.pathExtension == "json" else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}

/// The on-disk shape of the mutation records, and the mapping to and from domain models.
///
/// Separate from the domain type for the same reason ``InboxCacheDTO`` is: the file format is
/// an adapter concern, every key is written out explicitly, and an unrecognised version is
/// discarded rather than guessed at.
nonisolated enum MutationRecordDTO {

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

    struct File: Codable, Equatable {
        var version: Int
        var accountAddress: String
        var records: [Entry]

        enum CodingKeys: String, CodingKey {
            case version = "v"
            case accountAddress = "account"
            case records
        }
    }

    /// One record. Note what is not here: nothing describing the mail itself.
    struct Entry: Codable, Equatable {
        var id: String
        var operation: String
        var messageID: String
        var occurredAt: Date
        var outcome: String

        enum CodingKeys: String, CodingKey {
            case id
            case operation = "op"
            case messageID = "message_id"
            case occurredAt = "at"
            case outcome
        }
    }

    static func entry(from record: MailMutationRecord) -> Entry {
        Entry(
            id: record.id.uuidString,
            operation: record.operation.rawValue,
            messageID: record.messageID.rawValue,
            occurredAt: record.occurredAt,
            outcome: record.outcome.rawValue
        )
    }

    /// Rebuilds a record, or returns `nil` for an entry this build does not recognise.
    static func record(from entry: Entry, accountAddress: String) -> MailMutationRecord? {
        guard let id = UUID(uuidString: entry.id),
              let operation = MailMutationOperation(rawValue: entry.operation),
              let outcome = MailMutationRecord.Outcome(rawValue: entry.outcome)
        else { return nil }

        return MailMutationRecord(
            id: id,
            operation: operation,
            messageID: MailMessageID(entry.messageID),
            accountAddress: accountAddress,
            occurredAt: entry.occurredAt,
            outcome: outcome
        )
    }
}

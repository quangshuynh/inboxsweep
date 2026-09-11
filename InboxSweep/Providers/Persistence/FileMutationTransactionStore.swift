import CryptoKit
import Foundation

/// Stores one account's mutation transactions as a JSON file inside the app's own container.
///
/// Follows the mailbox cache and the plan store exactly: an actor so overlapping writes are
/// serialized, one file per account named by a digest of the address, owner-only permissions,
/// excluded from backups, and every other account's file removed on save.
///
/// ### What this file is *for* now
///
/// It used to be a receipt drawer. It is still that, and it is also the thing that makes undo
/// survive a relaunch: on the next launch the session reads the most recent undoable transaction
/// for the connected account out of this file and offers to put those messages back. That raises
/// the bar for what a malformed or half-written file is allowed to do, so every entry is
/// validated on the way in and an entry this build cannot fully understand is dropped rather
/// than guessed at — a dropped entry costs an undo offer, and a guessed one would mean sending
/// requests about messages nobody confirmed.
///
/// ### What ends up on disk
///
/// Provider message identifiers, an account address, an operation name, a selected count, a
/// timestamp, and an undo state. **No mail.** No subject, no sender, no body —
/// ``MailMutationTransaction`` has nowhere to put any of them.
///
/// Unlike the cache, this one *reports* whether a write succeeded. A cache that cannot be
/// written costs a refetch; a transaction that cannot be written means the app has changed a
/// mailbox, failed to write that down, and will not be able to offer the undo after a relaunch —
/// which the user is told about rather than left to discover.
actor FileMutationTransactionStore: MailMutationRecording {

    /// The container-relative directory the transaction file lives in.
    static let directoryName = "InboxSweep/Mutations"

    /// How many of the most recent transactions are kept.
    ///
    /// Bounded because this is a receipt drawer, not a log: the app performs one mutation per
    /// deliberate user action, and a file that grew without limit would be the first thing in
    /// InboxSweep that accumulated a history of somebody's mailbox.
    static let retainedTransactionLimit = 50

    /// The largest set a single stored transaction may name.
    ///
    /// A guard on the *reader* as much as the writer. Nothing in the app can confirm a set
    /// bigger than the loaded window, but this file is the one input to the undo path that does
    /// not come from Gmail, and an undo offer is a list of messages the app will send requests
    /// about. A entry claiming fifty thousand identifiers is not a transaction this app wrote.
    static let maximumMessagesPerTransaction = 5_000

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

    func record(_ transaction: MailMutationTransaction) async -> MutationRecordOutcome {
        guard let directory, let url = fileURL(forAccountAddress: transaction.accountAddress) else {
            return .notStored(reason: "InboxSweep couldn't find a place on this Mac to write the record.")
        }

        var transactions = loadTransactions(from: url).filter { $0.id != transaction.id }
        transactions.append(transaction)
        transactions.sort { $0.occurredAt > $1.occurredAt }
        transactions = Array(transactions.prefix(Self.retainedTransactionLimit))

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = MutationTransactionDTO.File(
                version: MutationTransactionDTO.schemaVersion,
                accountAddress: transaction.accountAddress,
                transactions: transactions.map(MutationTransactionDTO.entry(from:))
            )
            let data = try MutationTransactionDTO.makeEncoder().encode(file)
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

    func transactions(for account: MailAccount) async -> [MailMutationTransaction] {
        guard let url = fileURL(forAccountAddress: account.emailAddress.address) else { return [] }
        return loadTransactions(from: url)
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
    /// Non-throwing in every direction a read can go wrong: a file this build does not
    /// recognise, a file written for a different account, and an individual entry that does not
    /// parse. Neither is worth an error — the worst case is that an undo is not offered, which
    /// is strictly better than offering one built out of something unreadable.
    private func loadTransactions(from url: URL) -> [MailMutationTransaction] {
        guard let data = try? Data(contentsOf: url),
              let file = try? MutationTransactionDTO.makeDecoder().decode(MutationTransactionDTO.File.self, from: data),
              file.version == MutationTransactionDTO.schemaVersion
        else { return [] }

        return file.transactions.compactMap {
            MutationTransactionDTO.transaction(from: $0, accountAddress: file.accountAddress)
        }
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

    /// Keeps exactly one account's transactions on disk.
    private func discardFiles(otherThan keep: URL, in directory: URL) {
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent != keep.lastPathComponent {
            guard url.pathExtension == "json" else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}

/// The on-disk shape of the mutation transactions, and the mapping to and from domain models.
///
/// Separate from the domain type for the same reason ``InboxCacheDTO`` is: the file format is an
/// adapter concern, every key is written out explicitly, and an unrecognised version is discarded
/// rather than guessed at.
nonisolated enum MutationTransactionDTO {

    /// Bumped from 1 when the single-message record became a set transaction.
    ///
    /// A version-1 file is *discarded*, not migrated. It holds at most one single-message
    /// archive whose undo offer had already expired by design — the previous interval's offer
    /// did not survive a relaunch — so there is nothing in it worth carrying forward, and
    /// migrating would mean writing a decoder for a shape no user can still be relying on.
    static let schemaVersion = 2

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
        var transactions: [Entry]

        enum CodingKeys: String, CodingKey {
            case version = "v"
            case accountAddress = "account"
            case transactions
        }
    }

    /// One transaction. Note what is not here: nothing describing the mail itself.
    struct Entry: Codable, Equatable {
        var id: String
        var operation: String
        var messageIDs: [String]
        var selectedCount: Int
        var occurredAt: Date
        var undoState: String

        enum CodingKeys: String, CodingKey {
            case id
            case operation = "op"
            case messageIDs = "message_ids"
            case selectedCount = "selected"
            case occurredAt = "at"
            case undoState = "undo"
        }
    }

    static func entry(from transaction: MailMutationTransaction) -> Entry {
        Entry(
            id: transaction.id.uuidString,
            operation: transaction.operation.rawValue,
            messageIDs: transaction.succeededMessageIDs.map(\.rawValue),
            selectedCount: transaction.selectedMessageCount,
            occurredAt: transaction.occurredAt,
            undoState: transaction.undoState.rawValue
        )
    }

    /// Rebuilds a transaction, or returns `nil` for an entry this build cannot fully account
    /// for.
    ///
    /// Strict on purpose, because what comes out of here can become a list of messages the app
    /// sends undo requests about. An unknown operation, an unknown undo state, an empty
    /// identifier, an implausible count, or more identifiers than the app could ever have
    /// confirmed is an entry InboxSweep did not write, and it is dropped rather than partially
    /// honoured.
    static func transaction(from entry: Entry, accountAddress: String) -> MailMutationTransaction? {
        guard let id = UUID(uuidString: entry.id),
              let operation = MailMutationOperation(rawValue: entry.operation),
              let undoState = MailMutationTransaction.UndoState(rawValue: entry.undoState),
              entry.messageIDs.count <= FileMutationTransactionStore.maximumMessagesPerTransaction,
              entry.selectedCount >= entry.messageIDs.count,
              entry.selectedCount <= FileMutationTransactionStore.maximumMessagesPerTransaction,
              entry.messageIDs.allSatisfy({ !$0.isEmpty })
        else { return nil }

        // Duplicates would mean sending two requests for one message and counting it twice.
        var seen = Set<String>()
        let identifiers = entry.messageIDs.filter { seen.insert($0).inserted }
        guard identifiers.count == entry.messageIDs.count else { return nil }

        return MailMutationTransaction(
            id: id,
            operation: operation,
            accountAddress: accountAddress,
            succeededMessageIDs: identifiers.map { MailMessageID($0) },
            selectedMessageCount: entry.selectedCount,
            occurredAt: entry.occurredAt,
            undoState: undoState
        )
    }
}

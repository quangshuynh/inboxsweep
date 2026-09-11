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
/// Provider message identifiers, an account address, an operation name, two counts, a timestamp,
/// and an undo state. **No mail.** No subject, no sender, no snippet, no body —
/// ``MailMutationTransaction`` has nowhere to put any of them, and the Activity screen that
/// reads this file resolves what it can from the mailbox cache instead of copying it here.
///
/// Unlike the cache, this one *reports* whether a write succeeded. A cache that cannot be
/// written costs a refetch; a transaction that cannot be written means the app has changed a
/// mailbox, failed to write that down, and will not be able to offer the undo after a relaunch —
/// which the user is told about rather than left to discover.
actor FileMutationTransactionStore: MailMutationRecording {

    /// The container-relative directory the transaction file lives in.
    static let directoryName = "InboxSweep/Mutations"

    /// How many of the most recent transactions are kept, per account.
    ///
    /// The policy itself — including why this number and how ties are broken — lives in
    /// ``MailMutationHistory``, so the in-memory store and this one prune identically rather
    /// than coincidentally.
    static var retainedTransactionLimit: Int { MailMutationHistory.entryLimit }

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

        // Replace by identifier, then prune. Pruning on the way *out* as well as on the way in
        // is what keeps a file that somehow grew — an older build, a hand edit — from being read
        // back unbounded.
        var transactions = loadTransactions(from: url).filter { $0.id != transaction.id }
        transactions.append(transaction)
        transactions = MailMutationHistory.pruned(transactions)

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
        // Filtered by account before pruning, so a file whose header and entries disagree about
        // whose mailbox they describe cannot have one account's entries displace another's.
        return MailMutationHistory.history(loadTransactions(from: url), for: account)
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
              MutationTransactionDTO.readableVersions.contains(file.version)
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

    /// Bumped from 2 when the transaction gained the confirmed count the Activity history reads.
    ///
    /// A version-1 file is *discarded*, not migrated. It holds at most one single-message archive
    /// whose undo offer had already expired by design — that interval's offer did not survive a
    /// relaunch — so there is nothing in it worth carrying forward, and migrating would mean
    /// writing a decoder for a shape no user can still be relying on.
    static let schemaVersion = 3

    /// The versions this build will read.
    ///
    /// Version 2 is read rather than discarded, which is the opposite of what happened to
    /// version 1 and for a reason that did not apply then: a version-2 file can hold a **live
    /// undo offer**. Discarding it would mean somebody updates InboxSweep and quietly loses the
    /// ability to put back the messages they archived ten minutes earlier — a real change to
    /// what the app can do for them, made as a side effect of a schema bump.
    ///
    /// The one field version 2 lacks is the confirmed count, which defaults to the number of
    /// identifiers in the entry. That is exact for every version-2 entry except one that had
    /// already been narrowed by a partial undo, where it understates how many the archive
    /// originally confirmed. Understating is the safe direction: it can make an old row read as
    /// a smaller archive than it was, and it can never invent a message.
    static let readableVersions: Set<Int> = [2, 3]

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

        /// How many the operation confirmed when it ran. Absent in a version-2 file, where the
        /// identifier count is the answer.
        var confirmedCount: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case operation = "op"
            case messageIDs = "message_ids"
            case selectedCount = "selected"
            case occurredAt = "at"
            case undoState = "undo"
            case confirmedCount = "confirmed"
        }
    }

    static func entry(from transaction: MailMutationTransaction) -> Entry {
        Entry(
            id: transaction.id.uuidString,
            operation: transaction.operation.rawValue,
            messageIDs: transaction.succeededMessageIDs.map(\.rawValue),
            selectedCount: transaction.selectedMessageCount,
            occurredAt: transaction.occurredAt,
            undoState: transaction.undoState.rawValue,
            confirmedCount: transaction.confirmedMessageCount
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
        // A version-2 entry has no confirmed count, and its identifier count is what it means.
        let confirmedCount = entry.confirmedCount ?? entry.messageIDs.count

        guard let id = UUID(uuidString: entry.id),
              let operation = MailMutationOperation(rawValue: entry.operation),
              let undoState = MailMutationTransaction.UndoState(rawValue: entry.undoState),
              entry.messageIDs.count <= FileMutationTransactionStore.maximumMessagesPerTransaction,
              entry.selectedCount >= entry.messageIDs.count,
              entry.selectedCount <= FileMutationTransactionStore.maximumMessagesPerTransaction,
              entry.messageIDs.allSatisfy({ !$0.isEmpty }),
              // The confirmed count has to sit between what is still undoable and what was
              // selected. Outside that range it is not a count any run of this app produced,
              // and a history row built from it would claim something that never happened.
              confirmedCount >= entry.messageIDs.count,
              confirmedCount <= entry.selectedCount
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
            undoState: undoState,
            confirmedMessageCount: confirmedCount
        )
    }
}

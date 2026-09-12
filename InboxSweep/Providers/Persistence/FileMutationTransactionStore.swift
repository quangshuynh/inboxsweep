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
/// than guessed at: a dropped entry costs an undo offer, and a guessed one would mean sending
/// requests about messages nobody confirmed.
///
/// ### What ends up on disk
///
/// Provider message identifiers, an account address, an operation name, two counts, a timestamp,
/// and an undo state. **No mail.** No subject, no sender, no snippet, no body,
/// ``MailMutationTransaction`` has nowhere to put any of them, and the Activity screen that
/// reads this file resolves what it can from the mailbox cache instead of copying it here.
///
/// Unlike the cache, this one *reports* whether a write succeeded. A cache that cannot be
/// written costs a refetch; a transaction that cannot be written means the app has changed a
/// mailbox, failed to write that down, and will not be able to offer the undo after a relaunch,
/// which the user is told about rather than left to discover.
actor FileMutationTransactionStore: MailMutationRecording {

    /// The container-relative directory the transaction file lives in.
    static let directoryName = "InboxSweep/Mutations"

    /// How many of the most recent transactions are kept, per account.
    ///
    /// The policy itself (including why this number and how ties are broken) lives in
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
        guard let url = fileURL(forAccountAddress: transaction.accountAddress) else {
            return .notStored(reason: "InboxSweep couldn't find a place on this Mac to write the record.")
        }

        // Replace by identifier, then prune. Pruning on the way *out* as well as on the way in
        // is what keeps a file that somehow grew (an older build, a hand edit) from being read
        // back unbounded.
        let existing = load(from: url)
        var transactions = existing.transactions.filter { $0.id != transaction.id }
        transactions.append(transaction)

        return write(
            transactions: MailMutationHistory.pruned(transactions),
            // Carried through untouched. An archive is not an occasion to rewrite the
            // unsubscribe history, and a write that dropped the other half of the file would be
            // the app losing a record of something it really did to somebody's subscription.
            unsubscribes: existing.unsubscribes,
            accountAddress: transaction.accountAddress,
            to: url
        )
    }

    func record(_ entry: UnsubscribeActionRecord) async -> MutationRecordOutcome {
        guard let url = fileURL(forAccountAddress: entry.accountAddress) else {
            return .notStored(reason: "InboxSweep couldn't find a place on this Mac to write the record.")
        }

        let existing = load(from: url)
        var entries = existing.unsubscribes.filter { $0.id != entry.id }
        entries.append(entry)

        return write(
            transactions: existing.transactions,
            unsubscribes: MailMutationHistory.prunedUnsubscribes(entries),
            accountAddress: entry.accountAddress,
            to: url
        )
    }

    func unsubscribeEntries(for account: MailAccount) async -> [UnsubscribeActionRecord] {
        guard let url = fileURL(forAccountAddress: account.emailAddress.address) else { return [] }
        return MailMutationHistory.unsubscribeHistory(load(from: url).unsubscribes, for: account)
    }

    /// The one place the file is written, whichever kind of entry prompted it.
    ///
    /// Both halves go out together, every time. There is no code path that writes one and not
    /// the other, which is what makes "recording an archive cannot lose an unsubscribe" a
    /// property of the file rather than of a caller remembering to pass the right thing.
    private func write(
        transactions: [MailMutationTransaction],
        unsubscribes: [UnsubscribeActionRecord],
        accountAddress: String,
        to url: URL
    ) -> MutationRecordOutcome {
        guard let directory else {
            return .notStored(reason: "InboxSweep couldn't find a place on this Mac to write the record.")
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = MutationTransactionDTO.File(
                version: MutationTransactionDTO.schemaVersion,
                accountAddress: accountAddress,
                transactions: transactions.map(MutationTransactionDTO.entry(from:)),
                unsubscribes: unsubscribes.isEmpty ? nil : unsubscribes.map(MutationTransactionDTO.entry(from:))
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
        return MailMutationHistory.history(load(from: url).transactions, for: account)
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
    /// parse. Neither is worth an error: the worst case is that an undo is not offered, which
    /// is strictly better than offering one built out of something unreadable.
    private func load(from url: URL) -> StoredFile {
        guard let data = try? Data(contentsOf: url),
              let file = try? MutationTransactionDTO.makeDecoder().decode(MutationTransactionDTO.File.self, from: data),
              MutationTransactionDTO.readableVersions.contains(file.version)
        else { return StoredFile(transactions: [], unsubscribes: []) }

        return StoredFile(
            transactions: file.transactions.compactMap {
                MutationTransactionDTO.transaction(from: $0, accountAddress: file.accountAddress)
            },
            // Absent in a version-2 or version-3 file, which simply had no unsubscribe feature
            // to record anything for. Missing is empty, not unreadable, which is what lets a
            // file written before this interval keep its archive history and its live undo
            // offer rather than being discarded over a key that was not there.
            unsubscribes: (file.unsubscribes ?? []).compactMap {
                MutationTransactionDTO.unsubscribe(from: $0, accountAddress: file.accountAddress)
            }
        )
    }

    /// Both halves of the file, as read.
    private struct StoredFile {
        let transactions: [MailMutationTransaction]
        let unsubscribes: [UnsubscribeActionRecord]
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

    /// Bumped from 3 when the file gained a second kind of entry: unsubscribe actions.
    ///
    /// A version-1 file is *discarded*, not migrated. It holds at most one single-message archive
    /// whose undo offer had already expired by design: that interval's offer did not survive a
    /// relaunch, so there is nothing in it worth carrying forward, and migrating would mean
    /// writing a decoder for a shape no user can still be relying on.
    ///
    /// Versions 2 and 3 are still read, and the 3 → 4 change is the cheapest kind of migration
    /// there is: **a new optional key beside the existing one**. Nothing about a transaction
    /// changed, no entry is reinterpreted, and a version-3 file decodes with its archive history
    /// and its live undo offer intact and an empty unsubscribe list, which is exactly true,
    /// because a build that wrote version 3 could not perform an unsubscribe. That is what
    /// requirement 16 of this interval asks for: evolve only as much as needed, and leave the
    /// existing guarantees alone.
    ///
    /// Bumped from 4 in Interval 11 for the same kind of change, and it is worth saying that
    /// twice: **a new optional key beside the existing ones**. A transaction gained an origin,
    /// because a second thing can now cause one. Nothing about an existing entry is reinterpreted,
    /// and a version-4 file decodes with its archive history, its unsubscribe history, and its
    /// live undo offer intact, every transaction in it reading as
    /// ``MailMutationOrigin/confirmed``, which is exactly what those were, since rules did not
    /// exist when that file was written.
    static let schemaVersion = 5

    /// The versions this build will read.
    ///
    /// Version 2 is read rather than discarded, which is the opposite of what happened to
    /// version 1 and for a reason that did not apply then: a version-2 file can hold a **live
    /// undo offer**. Discarding it would mean somebody updates InboxSweep and quietly loses the
    /// ability to put back the messages they archived ten minutes earlier: a real change to
    /// what the app can do for them, made as a side effect of a schema bump.
    ///
    /// The one field version 2 lacks is the confirmed count, which defaults to the number of
    /// identifiers in the entry. That is exact for every version-2 entry except one that had
    /// already been narrowed by a partial undo, where it understates how many the archive
    /// originally confirmed. Understating is the safe direction: it can make an old row read as
    /// a smaller archive than it was, and it can never invent a message.
    static let readableVersions: Set<Int> = [2, 3, 4, 5]

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

        /// Unsubscribe actions, absent in every file written before version 4.
        ///
        /// A second array rather than a shared one with a discriminator field. The two kinds of
        /// entry have nothing in common but a timestamp: one names messages and carries an undo
        /// state, the other names a host and has no inverse. A shared shape would have meant
        /// every field being optional and every reader guessing which half it was looking at.
        var unsubscribes: [UnsubscribeEntry]?

        enum CodingKeys: String, CodingKey {
            case version = "v"
            case accountAddress = "account"
            case transactions
            case unsubscribes
        }
    }

    /// One unsubscribe action. Note what is not here: no URL path, no query, no mail address,
    /// no subject, no sender name; see ``UnsubscribeActionRecord`` for why the host alone.
    struct UnsubscribeEntry: Codable, Equatable {
        var id: String
        var mechanism: String
        var outcome: String
        var host: String
        var statusCode: Int?
        var sourceMessageID: String?
        var occurredAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case mechanism = "via"
            case outcome
            case host
            case statusCode = "status"
            case sourceMessageID = "message_id"
            case occurredAt = "at"
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

        /// What caused this operation. Absent before version 5, where the answer is that somebody
        /// confirmed it, because nothing else could have.
        var origin: String?

        enum CodingKeys: String, CodingKey {
            case id
            case operation = "op"
            case messageIDs = "message_ids"
            case selectedCount = "selected"
            case occurredAt = "at"
            case undoState = "undo"
            case confirmedCount = "confirmed"
            case origin
        }
    }

    static func entry(from record: UnsubscribeActionRecord) -> UnsubscribeEntry {
        UnsubscribeEntry(
            id: record.id.uuidString,
            mechanism: record.mechanism.rawValue,
            outcome: record.outcome.rawValue,
            host: record.destinationHost,
            statusCode: record.statusCode,
            sourceMessageID: record.sourceMessageID?.rawValue,
            occurredAt: record.occurredAt
        )
    }

    /// Rebuilds an unsubscribe entry, or returns `nil` for one this build cannot account for.
    ///
    /// Strict for a different reason than the transaction decoder's. Nothing that comes out of
    /// here becomes a request: an unsubscribe entry is read-only history with no action behind
    /// it, so the risk is not a stray write but a **false claim**: a row asserting InboxSweep
    /// sent a request it did not send, or sent one somewhere it did not. An entry with an
    /// unrecognised mechanism, an unrecognised outcome, an empty host, or an impossible status
    /// is not one this app wrote, and it is dropped rather than displayed.
    static func unsubscribe(from entry: UnsubscribeEntry, accountAddress: String) -> UnsubscribeActionRecord? {
        guard let id = UUID(uuidString: entry.id),
              let mechanism = UnsubscribeMechanism.Kind(rawValue: entry.mechanism),
              let outcome = UnsubscribeOutcome.Kind(rawValue: entry.outcome),
              !entry.host.isEmpty,
              entry.host.count <= maximumHostLength,
              entry.statusCode.map({ (100...599).contains($0) }) ?? true
        else { return nil }

        return UnsubscribeActionRecord(
            id: id,
            accountAddress: accountAddress,
            mechanism: mechanism,
            outcome: outcome,
            destinationHost: entry.host,
            statusCode: entry.statusCode,
            sourceMessageID: entry.sourceMessageID.flatMap { $0.isEmpty ? nil : MailMessageID($0) },
            occurredAt: entry.occurredAt
        )
    }

    /// The longest host this file will read back. A DNS name cannot exceed 253 characters, and
    /// a "host" longer than that is not a host.
    static let maximumHostLength = 253

    static func entry(from transaction: MailMutationTransaction) -> Entry {
        Entry(
            id: transaction.id.uuidString,
            operation: transaction.operation.rawValue,
            messageIDs: transaction.succeededMessageIDs.map(\.rawValue),
            selectedCount: transaction.selectedMessageCount,
            occurredAt: transaction.occurredAt,
            undoState: transaction.undoState.rawValue,
            confirmedCount: transaction.confirmedMessageCount,
            origin: transaction.origin.storedValue
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
              confirmedCount <= entry.selectedCount,
              // An origin this build does not recognise is an entry a later version wrote.
              // Dropped rather than defaulted: reading it as "somebody confirmed this" would put a
              // row in Activity claiming a person did something a rule did, and reading it as a
              // rule would invent an authorization. A missing key is not this case; it decodes as
              // ``MailMutationOrigin/confirmed``, which is what a pre-version-5 entry means.
              let origin = MailMutationOrigin.decoding(entry.origin)
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
            confirmedMessageCount: confirmedCount,
            origin: origin
        )
    }
}

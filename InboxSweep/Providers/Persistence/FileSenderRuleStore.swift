import CryptoKit
import Foundation

/// Stores one account's sender rules as a JSON file inside the app's own container.
///
/// Follows the mailbox cache, the plan store, and the mutation history exactly: an actor so
/// overlapping writes are serialized, one file per account named by a digest of the address,
/// owner-only permissions, excluded from backups, and every other account's file removed on save.
/// Deliberately the same shape as the three that came before it rather than a new idea, because
/// the guarantees are the same guarantees and a fourth way of writing a small local file is a
/// fourth place for one of them to be forgotten.
///
/// ### What ends up on disk, and the one new thing about it
///
/// A rule identifier, an account address, **a sender address**, a display value, an action name,
/// an enabled flag, and a timestamp.
///
/// The sender address is new, and it is the first mailbox content InboxSweep has ever written
/// down. The mutation history names messages by provider identifier and describes none of them;
/// the unsubscribe history keeps a destination host rather than a mailbox. Neither could tell you
/// who somebody corresponds with. A rules file can, for as many senders as the user has made
/// rules about.
///
/// That is unavoidable rather than incidental: a rule's whole job is to recognise a sender, and
/// there is no way to recognise one without holding something that identifies them. A digest was
/// considered and rejected: it would be matchable but not *displayable*, and a rules screen that
/// could not tell you which sender a rule was about would be a list of authorizations nobody
/// could audit, which is worse for the user than the file being readable by their own account.
///
/// So the exposure is bounded instead: at most ``SenderRuleRetention/ruleLimit`` addresses, only
/// ones the user deliberately chose, no subjects, no message identifiers, no match history, no
/// counts. Mode `0600`, excluded from Time Machine, and deleted along with the cache and the
/// history when the account is disconnected.
///
/// This is not analytics. Nothing here is aggregated, scored, or sent anywhere.
actor FileSenderRuleStore: SenderRuleStoring {

    /// The container-relative directory the rules file lives in.
    static let directoryName = "InboxSweep/Rules"

    /// How many rules are kept, per account. The policy itself lives in ``SenderRuleRetention``.
    static var retainedRuleLimit: Int { SenderRuleRetention.ruleLimit }

    /// The longest sender address this file will read back.
    ///
    /// A guard on the *reader*. Nothing the app writes can exceed it, but this file is an input
    /// to a code path that archives mail, and an entry claiming a kilobyte-long address is not one
    /// this app wrote. RFC 5321 caps a path at 256 octets; this is that, rounded up once.
    static let maximumAddressLength = 320

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

    // MARK: - SenderRuleStoring

    func rules(for account: MailAccount) async -> [SenderRule] {
        guard let url = fileURL(forAccountAddress: account.emailAddress.address) else { return [] }
        // Filtered by account before it is bounded, so a file whose header and entries disagree
        // about whose mailbox they describe cannot have one account's rules displace another's.
        return SenderRuleRetention.rules(load(from: url), for: account)
    }

    func save(_ rule: SenderRule) async -> SenderRuleWriteOutcome {
        guard let url = fileURL(forAccountAddress: rule.accountAddress) else {
            return .notStored(reason: "InboxSweep couldn't find a place on this Mac to write the rule.")
        }

        var existing = load(from: url).filter { $0.id != rule.id }
        existing.append(rule)
        return write(SenderRuleRetention.retained(existing), accountAddress: rule.accountAddress, to: url)
    }

    func delete(ruleID: SenderRule.ID, for account: MailAccount) async -> SenderRuleWriteOutcome {
        let address = account.emailAddress.address
        guard let url = fileURL(forAccountAddress: address) else {
            return .notStored(reason: "InboxSweep couldn't find the rules on this Mac.")
        }

        // Both halves of the predicate. Matching on the identifier alone would let a rule be
        // deleted out of a mailbox that is not the one on screen, which is the account isolation
        // this file otherwise has.
        let remaining = load(from: url).filter { !($0.id == ruleID && $0.accountAddress == address) }
        return write(SenderRuleRetention.retained(remaining), accountAddress: address, to: url)
    }

    func clear(for account: MailAccount) async {
        guard let url = fileURL(forAccountAddress: account.emailAddress.address) else { return }
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Internals

    private func write(
        _ rules: [SenderRule],
        accountAddress: String,
        to url: URL
    ) -> SenderRuleWriteOutcome {
        guard let directory else {
            return .notStored(reason: "InboxSweep couldn't find a place on this Mac to write the rule.")
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = SenderRuleDTO.File(
                version: SenderRuleDTO.schemaVersion,
                accountAddress: accountAddress,
                rules: rules.map(SenderRuleDTO.entry(from:))
            )
            let data = try SenderRuleDTO.makeEncoder().encode(file)
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path(percentEncoded: false)
            )
            excludeFromBackup(url)
            discardFiles(otherThan: url, in: directory)
            return .stored
        } catch {
            // Deliberately not the error's own description: a file-system error can name a path,
            // and the path names the account's digest.
            return .notStored(reason: "InboxSweep couldn't write the rule to this Mac.")
        }
    }

    /// Reads what is on disk, or nothing at all.
    ///
    /// Non-throwing in every direction a read can go wrong, and **strict**, because what comes out
    /// of here decides whether mail gets archived without anybody watching. A file this build does
    /// not recognise, a file written for a different account, an entry with an action this build
    /// cannot perform, an entry naming no sender: all of them are dropped rather than guessed at.
    /// A dropped entry costs a rule the user can re-create in two presses; a guessed one would
    /// archive somebody's mail on an authorization they never gave.
    private func load(from url: URL) -> [SenderRule] {
        guard let data = try? Data(contentsOf: url),
              let file = try? SenderRuleDTO.makeDecoder().decode(SenderRuleDTO.File.self, from: data),
              SenderRuleDTO.readableVersions.contains(file.version)
        else { return [] }

        return file.rules.compactMap {
            SenderRuleDTO.rule(from: $0, accountAddress: file.accountAddress)
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

    /// Keeps exactly one account's rules on disk.
    private func discardFiles(otherThan keep: URL, in directory: URL) {
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent != keep.lastPathComponent {
            guard url.pathExtension == "json" else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}

/// The on-disk shape of the sender rules, and the mapping to and from the domain model.
///
/// Separate from the domain type for the same reason ``InboxCacheDTO`` and
/// ``MutationTransactionDTO`` are: the file format is an adapter concern, every key is written out
/// explicitly, and an unrecognised version is discarded rather than guessed at.
nonisolated enum SenderRuleDTO {

    /// Version 1. There has never been another, because rules are new in Interval 11.
    ///
    /// Stated rather than implied so the migration posture is on the record from the start: when a
    /// second action or a second field arrives, the cheap move is a **new optional key beside the
    /// existing ones** and a bumped version that still reads 1, exactly as the mutation file's
    /// 3 → 4 change did. What must not happen is an old file being reinterpreted, because every
    /// entry in it is an authorization to change somebody's mailbox.
    static let schemaVersion = 1

    /// The versions this build will read.
    static let readableVersions: Set<Int> = [1]

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
        var rules: [Entry]

        enum CodingKeys: String, CodingKey {
            case version = "v"
            case accountAddress = "account"
            case rules
        }
    }

    /// One rule. Note what is not here: no subject, no message identifier, no match count, no
    /// record of what the rule has ever done. A rule is an instruction, not a log.
    struct Entry: Codable, Equatable {
        var id: String
        var senderKey: String
        var senderDisplayValue: String
        var action: String
        var isEnabled: Bool
        var createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case senderKey = "sender"
            case senderDisplayValue = "display"
            case action
            case isEnabled = "enabled"
            case createdAt = "at"
        }
    }

    static func entry(from rule: SenderRule) -> Entry {
        Entry(
            id: rule.id.uuidString,
            senderKey: rule.senderKey,
            senderDisplayValue: rule.senderDisplayValue,
            action: rule.action.rawValue,
            isEnabled: rule.isEnabled,
            createdAt: rule.createdAt
        )
    }

    /// Rebuilds a rule, or returns `nil` for one this build must not act on.
    ///
    /// Every guard here is the difference between a missing rule and an unauthorized archive:
    ///
    /// - an unparseable identifier is not one this app generated;
    /// - an **unrecognised action** is a rule from a later build, and running it as the one action
    ///   this build happens to have would be performing a verb the user authorized something else
    ///   for;
    /// - an empty sender, or the unknown-sender bucket, is not an identity: it is "anything whose
    ///   header did not parse", which is precisely the fuzzy match this feature refuses;
    /// - an absurdly long address is not an address.
    static func rule(from entry: Entry, accountAddress: String) -> SenderRule? {
        guard let id = UUID(uuidString: entry.id),
              let action = SenderRule.Action(rawValue: entry.action),
              !entry.senderKey.isEmpty,
              entry.senderKey != EmailAddress.unknownGroupingKey,
              entry.senderKey.count <= FileSenderRuleStore.maximumAddressLength,
              !accountAddress.isEmpty
        else { return nil }

        return SenderRule(
            id: id,
            accountAddress: accountAddress,
            senderKey: entry.senderKey,
            // Falls back to the address rather than to an empty string: a rules row has to name
            // its sender, and an entry whose display value was lost is still a valid rule.
            senderDisplayValue: entry.senderDisplayValue.isEmpty ? entry.senderKey : entry.senderDisplayValue,
            action: action,
            isEnabled: entry.isEnabled,
            createdAt: entry.createdAt
        )
    }
}

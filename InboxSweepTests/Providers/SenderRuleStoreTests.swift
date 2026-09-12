import Foundation
import Testing
@testable import InboxSweep

/// The rules file: what it keeps, what it refuses to read back, and who it belongs to.
///
/// Driven against the real ``FileSenderRuleStore`` in a temporary directory rather than against
/// the in-memory one, because most of what this suite is about is the file: its permissions, its
/// version, its account isolation, and its strictness on the way in. A rule is an instruction to
/// change somebody's mailbox without asking, so a rules file that is trusted too readily is the
/// one place a corrupted byte could become an unauthorized archive.
@Suite("Sender rule storage")
struct SenderRuleStoreTests {

    nonisolated static let account = MailAccount(
        emailAddress: EmailAddressParser.parse("sample.user@example.com"),
        providerDisplayName: "Stub",
        providerMessageCount: 10
    )

    nonisolated static let otherAccount = MailAccount(
        emailAddress: EmailAddressParser.parse("someone.else@example.com"),
        providerDisplayName: "Stub",
        providerMessageCount: 10
    )

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "InboxSweepRuleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func rule(
        sender: String = "news@example.com",
        account: MailAccount = SenderRuleStoreTests.account,
        enabled: Bool = true,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SenderRule {
        SenderRule(
            accountAddress: account.emailAddress.address,
            senderKey: sender,
            senderDisplayValue: sender,
            action: .archiveNewInboxMail,
            isEnabled: enabled,
            createdAt: createdAt
        )
    }

    // MARK: - Round trip

    @Test("A saved rule comes back exactly as it went in")
    func roundTrips() async throws {
        let directory = try makeDirectory()
        let store = FileSenderRuleStore(directory: directory)
        let saved = rule()

        #expect(await store.save(saved) == .stored)
        #expect(await store.rules(for: Self.account) == [saved])
    }

    @Test("Saving the same rule again replaces it rather than appending")
    func savesAreIdempotent() async throws {
        let store = FileSenderRuleStore(directory: try makeDirectory())
        let original = rule()

        _ = await store.save(original)
        _ = await store.save(original.settingEnabled(false))

        let stored = await store.rules(for: Self.account)
        #expect(stored.count == 1)
        #expect(stored.first?.isEnabled == false)
    }

    @Test("Two rules for one sender collapse to the newest, because that is one decision")
    func oneRulePerSenderSurvives() async throws {
        let store = FileSenderRuleStore(directory: try makeDirectory())
        let older = rule(createdAt: Date(timeIntervalSince1970: 1_600_000_000))
        let newer = rule(createdAt: Date(timeIntervalSince1970: 1_700_000_000))

        _ = await store.save(older)
        _ = await store.save(newer)

        let stored = await store.rules(for: Self.account)
        #expect(stored.count == 1)
        #expect(stored.first?.id == newer.id)
    }

    @Test("The file is owner-readable only and excluded from backups")
    func fileIsProtected() async throws {
        let directory = try makeDirectory()
        let store = FileSenderRuleStore(directory: directory)
        _ = await store.save(rule())

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )
        let permissions = try #require(
            try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.posixPermissions] as? NSNumber
        )
        #expect(permissions.int16Value == 0o600)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        // The file name is a digest, so a directory listing does not name the account.
        #expect(!file.lastPathComponent.contains("@"))
        #expect(!file.lastPathComponent.contains("sample.user"))
    }

    @Test("The file holds the sender address and nothing describing a message")
    func fileHoldsOnlyWhatMatchingNeeds() async throws {
        let directory = try makeDirectory()
        let store = FileSenderRuleStore(directory: directory)
        _ = await store.save(rule())

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )
        let contents = String(decoding: try Data(contentsOf: file), as: UTF8.self)

        // The one new exposure, stated rather than hidden: a rules file names senders, because
        // matching one is what a rule does.
        #expect(contents.contains("news@example.com"))
        // And nothing else about anybody's mail.
        for absent in ["subject", "snippet", "body", "messageIDs", "matchCount", "lastRun"] {
            #expect(!contents.lowercased().contains(absent.lowercased()), "The rules file holds \(absent)")
        }
    }

    // MARK: - Account isolation

    @Test("One account's rules are invisible to another, and saving keeps one file")
    func accountsAreIsolated() async throws {
        let directory = try makeDirectory()
        let store = FileSenderRuleStore(directory: directory)

        _ = await store.save(rule())
        _ = await store.save(rule(sender: "other@example.com", account: Self.otherAccount))

        #expect(await store.rules(for: Self.account).isEmpty)
        #expect(await store.rules(for: Self.otherAccount).count == 1)

        // Exactly one file on disk. Signing into a second account does not leave the first
        // account's rules behind, which is what the cache and the mutation history already do.
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(files.count == 1)
    }

    @Test("Clearing an account removes its rules entirely")
    func clearingRemovesTheFile() async throws {
        let directory = try makeDirectory()
        let store = FileSenderRuleStore(directory: directory)
        _ = await store.save(rule())

        await store.clear(for: Self.account)

        #expect(await store.rules(for: Self.account).isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(files.isEmpty)
    }

    // MARK: - Retention

    @Test("The limit refuses a new rule rather than evicting an old one")
    func retentionIsBounded() {
        let rules = (0..<SenderRuleRetention.ruleLimit).map {
            rule(sender: "sender-\($0)@example.com", createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)))
        }
        #expect(SenderRuleRetention.isAtCapacity(rules))
        #expect(!SenderRuleRetention.isAtCapacity(Array(rules.dropLast())))

        // Retention itself is still a bound, for a file that somehow grew.
        let overflowing = rules + [rule(sender: "one-too-many@example.com")]
        #expect(SenderRuleRetention.retained(overflowing).count == SenderRuleRetention.ruleLimit)
    }

    @Test("The order is total, so the same file lists the same way every launch")
    func orderingIsDeterministic() {
        let sameSecond = Date(timeIntervalSince1970: 1_700_000_000)
        let rules = (0..<8).map { rule(sender: "sender-\($0)@example.com", createdAt: sameSecond) }

        // Shuffling the input must not change the output, which is what an identifier tiebreak
        // buys over a merely-descending sort.
        #expect(SenderRuleRetention.sorted(rules).map(\.id) == SenderRuleRetention.sorted(rules.reversed()).map(\.id))
    }

    // MARK: - Reading back what this build did not write

    @Test("The schema is version 1, and nothing else is read")
    func schemaVersion() {
        #expect(SenderRuleDTO.schemaVersion == 1)
        #expect(SenderRuleDTO.readableVersions == [1])
    }

    @Test("A file from a version this build does not know is ignored, not guessed at")
    func unreadableVersionsAreIgnored() async throws {
        let directory = try makeDirectory()
        let store = FileSenderRuleStore(directory: directory)
        _ = await store.save(rule())

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )
        var contents = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        contents = contents.replacingOccurrences(of: "\"v\":1", with: "\"v\":99")
        try Data(contents.utf8).write(to: file)

        #expect(await store.rules(for: Self.account).isEmpty)
    }

    @Test("An entry this build cannot account for is dropped rather than honoured")
    func implausibleEntriesAreDropped() {
        func entry(
            id: String = UUID().uuidString,
            sender: String = "news@example.com",
            action: String = SenderRule.Action.archiveNewInboxMail.rawValue
        ) -> SenderRuleDTO.Entry {
            SenderRuleDTO.Entry(
                id: id,
                senderKey: sender,
                senderDisplayValue: "News",
                action: action,
                isEnabled: true,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
        let address = Self.account.emailAddress.address

        #expect(SenderRuleDTO.rule(from: entry(), accountAddress: address) != nil)
        #expect(SenderRuleDTO.rule(from: entry(id: "not-a-uuid"), accountAddress: address) == nil)
        #expect(SenderRuleDTO.rule(from: entry(sender: ""), accountAddress: address) == nil)
        #expect(SenderRuleDTO.rule(from: entry(action: "trashEverything"), accountAddress: address) == nil)
        #expect(SenderRuleDTO.rule(from: entry(), accountAddress: "") == nil)

        // An address longer than RFC 5321 permits is not an address.
        let absurd = String(repeating: "a", count: FileSenderRuleStore.maximumAddressLength + 1)
        #expect(SenderRuleDTO.rule(from: entry(sender: absurd), accountAddress: address) == nil)
    }

    @Test("A rule whose display value was lost still names its sender")
    func displayValueFallsBackToTheAddress() {
        let entry = SenderRuleDTO.Entry(
            id: UUID().uuidString,
            senderKey: "news@example.com",
            senderDisplayValue: "",
            action: SenderRule.Action.archiveNewInboxMail.rawValue,
            isEnabled: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        // A rules row that could not say which sender it was about would be an authorization
        // nobody could audit, so an empty display value falls back rather than being dropped.
        let decoded = SenderRuleDTO.rule(from: entry, accountAddress: Self.account.emailAddress.address)
        #expect(decoded?.senderDisplayValue == "news@example.com")
    }
}

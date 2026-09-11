import Foundation
import Testing
@testable import InboxSweep

/// The second kind of entry on disk, and the guarantee that adding it changed nothing about
/// the first.
@Suite("Unsubscribe history on disk")
struct UnsubscribeHistoryStoreTests {

    static let account = MailAccount(
        emailAddress: EmailAddressParser.parse("someone@example.com"),
        providerDisplayName: "Gmail"
    )
    static let otherAccount = MailAccount(
        emailAddress: EmailAddressParser.parse("somebody.else@example.com"),
        providerDisplayName: "Gmail"
    )

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "InboxSweepUnsubscribeTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func record(
        _ id: UUID = UUID(),
        account: MailAccount = UnsubscribeHistoryStoreTests.account,
        mechanism: UnsubscribeMechanism.Kind = .oneClick,
        outcome: UnsubscribeOutcome.Kind = .requestAccepted,
        host: String = "lists.example",
        statusCode: Int? = 200,
        messageID: MailMessageID? = MailMessageID("m1"),
        at date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> UnsubscribeActionRecord {
        UnsubscribeActionRecord(
            id: id,
            accountAddress: account.emailAddress.address,
            mechanism: mechanism,
            outcome: outcome,
            destinationHost: host,
            statusCode: statusCode,
            sourceMessageID: messageID,
            occurredAt: date
        )
    }

    private func transaction(at date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> MailMutationTransaction {
        MailMutationTransaction(
            id: UUID(),
            operation: .archive,
            accountAddress: Self.account.emailAddress.address,
            succeededMessageIDs: [MailMessageID("m1"), MailMessageID("m2")],
            selectedMessageCount: 2,
            occurredAt: date,
            undoState: .undoable
        )
    }

    // MARK: - Round trip

    @Test("An unsubscribe entry survives a write and a read")
    func roundTrip() async throws {
        let store = FileMutationTransactionStore(directory: temporaryDirectory())
        let written = record()

        #expect(await store.record(written).isStored)

        let read = await store.unsubscribeEntries(for: Self.account)
        #expect(read == [written])
    }

    @Test("Writing one kind of entry never drops the other")
    func bothKindsCoexist() async throws {
        let store = FileMutationTransactionStore(directory: temporaryDirectory())
        let archive = transaction()
        let unsubscribe = record()

        _ = await store.record(archive)
        _ = await store.record(unsubscribe)
        // And again in the other order, which is where a write that rebuilt the file from one
        // half would lose the other.
        _ = await store.record(record(at: Date(timeIntervalSince1970: 1_700_000_100)))
        _ = await store.record(archive.settingUndoState(.superseded))

        #expect(await store.transactions(for: Self.account).count == 1)
        #expect(await store.unsubscribeEntries(for: Self.account).count == 2)
        // The archive's undo lifecycle is intact despite the unsubscribe writes between.
        #expect(await store.transactions(for: Self.account)[0].undoState == .superseded)
    }

    @Test("Entries are replaced by identifier, so one confirmation is one entry")
    func replacesByIdentifier() async {
        let store = FileMutationTransactionStore(directory: temporaryDirectory())
        let id = UUID()

        _ = await store.record(record(id, outcome: .requestAccepted))
        _ = await store.record(record(id, outcome: .requestFailed, statusCode: 500))

        let entries = await store.unsubscribeEntries(for: Self.account)
        #expect(entries.count == 1)
        #expect(entries[0].outcome == .requestFailed)
    }

    @Test("One account's entries are never read beside another's mailbox")
    func accountIsolation() async {
        let store = FileMutationTransactionStore(directory: temporaryDirectory())

        _ = await store.record(record(account: Self.account))
        // Writing for a second account discards the first account's file entirely, exactly as
        // the archive history does — one account's history on disk at a time.
        _ = await store.record(record(account: Self.otherAccount))

        #expect(await store.unsubscribeEntries(for: Self.account).isEmpty)
        #expect(await store.unsubscribeEntries(for: Self.otherAccount).count == 1)
    }

    @Test("Signing out removes both kinds of entry")
    func clearRemovesBoth() async {
        let store = FileMutationTransactionStore(directory: temporaryDirectory())
        _ = await store.record(transaction())
        _ = await store.record(record())

        await store.clear(for: Self.account)

        #expect(await store.transactions(for: Self.account).isEmpty)
        #expect(await store.unsubscribeEntries(for: Self.account).isEmpty)
    }

    // MARK: - Retention

    @Test("Unsubscribe entries are bounded, newest first, on their own budget")
    func retention() async {
        let store = FileMutationTransactionStore(directory: temporaryDirectory())
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<(MailMutationHistory.unsubscribeEntryLimit + 25) {
            _ = await store.record(record(at: base.addingTimeInterval(Double(index))))
        }

        let entries = await store.unsubscribeEntries(for: Self.account)
        #expect(entries.count == MailMutationHistory.unsubscribeEntryLimit)
        // Newest first, and the oldest are the ones that went.
        #expect(entries[0].occurredAt > entries[1].occurredAt)
        #expect(entries.last!.occurredAt >= base.addingTimeInterval(25))
    }

    @Test("A burst of archiving cannot evict the record of an unsubscribe")
    func separateBudgets() async {
        let store = FileMutationTransactionStore(directory: temporaryDirectory())
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let unsubscribe = record(at: base)

        _ = await store.record(unsubscribe)
        for index in 0..<(MailMutationHistory.entryLimit + 20) {
            _ = await store.record(
                MailMutationTransaction(
                    id: UUID(),
                    operation: .archive,
                    accountAddress: Self.account.emailAddress.address,
                    succeededMessageIDs: [MailMessageID("m\(index)")],
                    selectedMessageCount: 1,
                    occurredAt: base.addingTimeInterval(Double(index) + 1),
                    undoState: .notUndoable
                )
            )
        }

        #expect(await store.transactions(for: Self.account).count == MailMutationHistory.entryLimit)
        #expect(await store.unsubscribeEntries(for: Self.account) == [unsubscribe])
    }

    @Test("Ordering is total, so two entries in the same second do not swap between launches")
    func orderingIsDeterministic() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = (1...12).map { _ in record(at: at) }

        let orders = (1...10).map { _ in MailMutationHistory.sortedUnsubscribes(entries.shuffled()).map(\.id) }
        #expect(Set(orders.map { $0.map(\.uuidString).joined() }).count == 1)
    }

    // MARK: - Migration

    @Test("A version-3 file keeps its archive history and its live undo offer")
    func versionThreeStillReads() async throws {
        // The guarantee requirement 16 asks to be preserved: somebody updates InboxSweep and
        // does not lose the ability to put back what they archived ten minutes earlier.
        let directory = temporaryDirectory()
        let store = FileMutationTransactionStore(directory: directory)
        let archive = transaction()

        // Let the store choose the filename — it is a digest of the address — and then replace
        // the contents with what a version-3 build would have written.
        _ = await store.record(archive)
        let url = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        let legacy = MutationTransactionDTO.File(
            version: 3,
            accountAddress: Self.account.emailAddress.address,
            transactions: [MutationTransactionDTO.entry(from: archive)],
            unsubscribes: nil
        )
        try MutationTransactionDTO.makeEncoder().encode(legacy).write(to: url)

        let transactions = await store.transactions(for: Self.account)
        #expect(transactions.count == 1)
        #expect(transactions[0].isUndoable)
        #expect(await store.latestUndoableTransaction(for: Self.account)?.id == archive.id)
        // Missing is empty, not unreadable.
        #expect(await store.unsubscribeEntries(for: Self.account).isEmpty)
    }

    @Test("The current schema is 4, and 2 and 3 are still readable")
    func schemaVersions() {
        // Bumped to 5 in Interval 11, when a transaction gained an origin. Version 4 is still
        // read, and reads exactly as it meant: rules did not exist when it was written, so every
        // entry in it came from somebody pressing a confirming button.
        #expect(MutationTransactionDTO.schemaVersion == 5)
        #expect(MutationTransactionDTO.readableVersions == [2, 3, 4, 5])
    }

    @Test("An entry this build cannot account for is dropped rather than displayed")
    func rejectsImplausibleEntries() {
        let address = Self.account.emailAddress.address

        func entry(
            id: String = UUID().uuidString,
            mechanism: String = "oneClick",
            outcome: String = "requestAccepted",
            host: String = "lists.example",
            status: Int? = 200
        ) -> MutationTransactionDTO.UnsubscribeEntry {
            MutationTransactionDTO.UnsubscribeEntry(
                id: id,
                mechanism: mechanism,
                outcome: outcome,
                host: host,
                statusCode: status,
                sourceMessageID: "m1",
                occurredAt: .now
            )
        }

        #expect(MutationTransactionDTO.unsubscribe(from: entry(), accountAddress: address) != nil)

        // A row claiming a mechanism, an outcome, a host, or a status this app never produces is
        // a row that would assert InboxSweep did something it did not.
        #expect(MutationTransactionDTO.unsubscribe(from: entry(id: "not-a-uuid"), accountAddress: address) == nil)
        #expect(MutationTransactionDTO.unsubscribe(from: entry(mechanism: "createFilter"), accountAddress: address) == nil)
        #expect(MutationTransactionDTO.unsubscribe(from: entry(outcome: "unsubscribed"), accountAddress: address) == nil)
        #expect(MutationTransactionDTO.unsubscribe(from: entry(host: ""), accountAddress: address) == nil)
        #expect(MutationTransactionDTO.unsubscribe(from: entry(host: String(repeating: "a", count: 400)), accountAddress: address) == nil)
        #expect(MutationTransactionDTO.unsubscribe(from: entry(status: 9_999), accountAddress: address) == nil)
        #expect(MutationTransactionDTO.unsubscribe(from: entry(status: 0), accountAddress: address) == nil)
        // A handoff has no status, and that is legitimate.
        #expect(MutationTransactionDTO.unsubscribe(from: entry(mechanism: "webPage", outcome: "browserOpened", status: nil), accountAddress: address) != nil)
    }

    @Test("What reaches disk is a host and an identifier, and no mail")
    func writesNoMailContent() async throws {
        let directory = temporaryDirectory()
        let store = FileMutationTransactionStore(directory: directory)

        _ = await store.record(
            record(host: "lists.example", messageID: MailMessageID("gmail-message-id"))
        )

        let url = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        let contents = try String(contentsOf: url, encoding: .utf8)

        // The host and the message identifier are there — the first so the row can say what was
        // done, the second so the sender can be resolved from the cache instead of stored here.
        #expect(contents.contains("lists.example"))
        #expect(contents.contains("gmail-message-id"))
        // The full URL, its path, its query, and any address are not.
        #expect(!contents.contains("/u/abc"))
        #expect(!contents.contains("https://"))
        #expect(!contents.contains("mailto:"))
        #expect(!contents.contains("subject"))
        #expect(!contents.contains("Issue"))
    }

    // MARK: - The in-memory store behaves the same way

    @Test("The ephemeral store applies the same retention and isolation")
    func ephemeralStoreMatches() async {
        let store = EphemeralMutationRecordStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<(MailMutationHistory.unsubscribeEntryLimit + 5) {
            _ = await store.record(record(at: base.addingTimeInterval(Double(index))))
        }
        _ = await store.record(record(account: Self.otherAccount))

        #expect(await store.unsubscribeEntries(for: Self.account).count == MailMutationHistory.unsubscribeEntryLimit)
        #expect(await store.unsubscribeEntries(for: Self.otherAccount).count == 1)

        await store.clear(for: Self.account)
        #expect(await store.unsubscribeEntries(for: Self.account).isEmpty)
        #expect(await store.unsubscribeEntries(for: Self.otherAccount).count == 1)
    }

    @Test("A store that keeps no unsubscribe history says so rather than pretending")
    func storesWithoutUnsubscribeSupportReportHonestly() async {
        // The protocol default. A test double written for archive history alone keeps compiling
        // and reports a write that did not happen as one that did not happen.
        let store = FailingMutationRecordStore()
        let outcome = await store.record(record())

        #expect(!outcome.isStored)
        #expect(outcome.warning != nil)
        #expect(await store.unsubscribeEntries(for: Self.account).isEmpty)
    }
}

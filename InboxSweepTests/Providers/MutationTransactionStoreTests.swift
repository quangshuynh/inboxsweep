import Foundation
import Testing
@testable import InboxSweep

/// The on-disk mutation transaction: what it holds, what it refuses to hold, and how it behaves
/// when the file is missing, unreadable, or somebody else's.
///
/// This file matters more than it did when it held single-message records. It is now what makes
/// undo survive a relaunch, so what comes out of it becomes a list of messages the app sends
/// requests about, which is why the malformed-entry cases below are as detailed as the
/// round-trip ones.
///
/// Writes to a temporary directory, never to the developer's own container.
@Suite("Mutation transaction store")
struct MutationTransactionStoreTests {

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func temporaryDirectory() -> URL {
        URL.temporaryDirectory.appending(path: "InboxSweepMutationTests-\(UUID().uuidString)")
    }

    private func account(_ address: String = "sample.user@example.com") -> MailAccount {
        MailAccount(
            emailAddress: EmailAddressParser.parse(address),
            providerDisplayName: "Gmail"
        )
    }

    private func transaction(
        _ id: UUID = UUID(),
        operation: MailMutationOperation = .archive,
        messageIDs: [String] = ["m-1"],
        selectedCount: Int? = nil,
        confirmedCount: Int? = nil,
        account address: String = "sample.user@example.com",
        secondsAfterEpoch: TimeInterval = 0,
        undoState: MailMutationTransaction.UndoState = .undoable
    ) -> MailMutationTransaction {
        MailMutationTransaction(
            id: id,
            operation: operation,
            accountAddress: address,
            succeededMessageIDs: messageIDs.map { MailMessageID($0) },
            selectedMessageCount: selectedCount ?? confirmedCount ?? messageIDs.count,
            occurredAt: Self.epoch.addingTimeInterval(secondsAfterEpoch),
            undoState: undoState,
            confirmedMessageCount: confirmedCount
        )
    }

    @Test("A record round-trips through the file")
    func roundTrips() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileMutationTransactionStore(directory: directory)
        let written = transaction(operation: .archive, messageIDs: ["m-42", "m-43"], selectedCount: 3)

        #expect(await store.record(written) == .stored)

        let readBack = await store.transactions(for: account())
        #expect(readBack == [written])
    }

    @Test("Records come back newest first, however they were written")
    func ordersNewestFirst() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)

        _ = await store.record(transaction(messageIDs: ["middle"], secondsAfterEpoch: 60))
        _ = await store.record(transaction(messageIDs: ["oldest"], secondsAfterEpoch: 0))
        _ = await store.record(transaction(messageIDs: ["newest"], secondsAfterEpoch: 120))

        let ordered = await store.transactions(for: account()).compactMap(\.messageID?.rawValue)
        #expect(ordered == ["newest", "middle", "oldest"])
    }

    @Test("Writing the same operation twice replaces the record rather than adding one")
    func replacesByOperationID() async throws {
        // This is what makes a repeated completion callback safe: one logical mutation is one
        // record, whether the app wrote it once or three times.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)
        let id = UUID()

        _ = await store.record(transaction(id, messageIDs: [], selectedCount: 2, undoState: .notUndoable))
        _ = await store.record(transaction(id, messageIDs: ["m-1", "m-2"], selectedCount: 2))
        _ = await store.record(transaction(id, messageIDs: ["m-1", "m-2"], selectedCount: 2))

        let stored = await store.transactions(for: account())
        #expect(stored.count == 1)
        #expect(stored[0].outcome == .confirmed)
        #expect(stored[0].succeededMessageIDs.count == 2)
    }

    @Test("Only the most recent records are kept")
    func boundsTheFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)

        let limit = FileMutationTransactionStore.retainedTransactionLimit
        for index in 0..<(limit + 10) {
            _ = await store.record(transaction(messageIDs: ["m-\(index)"], secondsAfterEpoch: Double(index)))
        }

        let stored = await store.transactions(for: account())
        #expect(stored.count == limit, "The record file grew past its bound")
        // The newest survive; the oldest ten are gone.
        #expect(stored.first?.messageID == MailMessageID("m-\(limit + 9)"))
        #expect(!stored.contains { $0.succeededMessageIDs.contains(MailMessageID("m-0")) })
    }

    @Test("One account's records are never read back for another")
    func isolatesAccounts() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)

        _ = await store.record(transaction(account: "first@example.com"))
        #expect(await store.transactions(for: account("second@example.net")).isEmpty)

        // And writing for a second account leaves nothing of the first behind on disk.
        _ = await store.record(transaction(messageIDs: ["m-2"], account: "second@example.net"))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(files.count == 1, "A second account left the first account's file on disk")
        #expect(await store.transactions(for: account("first@example.com")).isEmpty)
    }

    @Test("Clearing removes the file")
    func clearing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)

        _ = await store.record(transaction())
        await store.clear(for: account())

        #expect(await store.transactions(for: account()).isEmpty)
    }

    @Test("A corrupt or future-version file is discarded rather than guessed at")
    func discardsUnusableFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)
        _ = await store.record(transaction())

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )

        try Data("{ not json at all".utf8).write(to: file)
        #expect(await store.transactions(for: account()).isEmpty)

        let future = """
            { "v": 999, "account": "sample.user@example.com", "transactions": [] }
            """
        try Data(future.utf8).write(to: file)
        #expect(await store.transactions(for: account()).isEmpty)
    }

    @Test("The file is owner-only and excluded from backups")
    func fileIsProtected() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)
        _ = await store.record(transaction())

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )

        let permissions = try #require(
            try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.posixPermissions] as? NSNumber
        )
        #expect(permissions.int16Value == 0o600)
        #expect(
            try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
            "Not excluded from backups: \(file.path(percentEncoded: false))"
        )
    }

    @Test("The file names messages and never describes them")
    func fileHoldsNoMail() async throws {
        // The record exists for undo and for the user's own visibility. Copying a subject or a
        // sender in would put the same mailbox content in a second file for no gain: the cache
        // already holds it for every message in the loaded window.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)
        _ = await store.record(transaction(messageIDs: ["18f2c9a"]))

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )
        let contents = String(decoding: try Data(contentsOf: file), as: UTF8.self)

        #expect(contents.contains("18f2c9a"))
        #expect(contents.contains("archive"))
        for absent in ["subject", "Subject", "from", "body", "snippet", "labels", "token"] {
            #expect(!contents.contains(absent), "The record file carried \(absent)")
        }
    }

    @Test("A partially successful transaction round-trips with its counts intact")
    func partialTransactionRoundTrips() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)

        // Eight archived out of twelve selected. Both numbers have to survive: the identifiers
        // are what undo acts on, and the selected count is what lets the history say "8 of 12"
        // rather than presenting eight as the whole story.
        let written = transaction(
            messageIDs: (1...8).map { "m-\($0)" },
            selectedCount: 12
        )
        #expect(await store.record(written) == .stored)

        let readBack = try #require(await store.transactions(for: account()).first)
        #expect(readBack == written)
        #expect(readBack.succeededCount == 8)
        #expect(readBack.selectedMessageCount == 12)
        #expect(readBack.failedMessageCount == 4)
        #expect(readBack.outcome == .partiallyConfirmed)
        #expect(readBack.isUndoable)
    }

    @Test("Only the most recent undoable transaction is offered")
    func latestUndoableWins() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)

        _ = await store.record(transaction(messageIDs: ["old"], secondsAfterEpoch: 0, undoState: .superseded))
        _ = await store.record(transaction(messageIDs: ["undone"], secondsAfterEpoch: 60, undoState: .undone))
        _ = await store.record(transaction(messageIDs: ["current"], secondsAfterEpoch: 120, undoState: .undoable))

        let offered = try #require(await store.latestUndoableTransaction(for: account()))
        #expect(offered.messageID == MailMessageID("current"))

        // Nothing is offered for an account that has no undoable transaction of its own.
        #expect(await store.latestUndoableTransaction(for: account("second@example.net")) == nil)
    }

    @Test("A restore transaction is stored, and is never itself offered as an undo")
    func restoresAreNotUndoable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)

        _ = await store.record(transaction(
            operation: .restoreToInbox,
            messageIDs: ["m-1"],
            undoState: .notUndoable
        ))

        #expect(await store.transactions(for: account()).count == 1)
        #expect(await store.latestUndoableTransaction(for: account()) == nil)
    }

    @Test("An entry this build cannot fully account for is dropped, not partly honoured")
    func malformedEntriesAreDropped() async throws {
        // This file is now an input to the undo path: what comes out of it becomes a list of
        // messages the app sends requests about. So an entry that is not unambiguously something
        // InboxSweep wrote is discarded. The cost is an undo offer; the alternative is asking
        // Gmail about messages nobody confirmed.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)
        _ = await store.record(transaction(messageIDs: ["good"]))

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )

        let unusableEntries = [
            // An operation this build has never heard of.
            #"{"id":"\#(UUID().uuidString)","op":"trash","message_ids":["m-1"],"selected":1,"at":0,"undo":"undoable"}"#,
            // An undo state this build has never heard of.
            #"{"id":"\#(UUID().uuidString)","op":"archive","message_ids":["m-1"],"selected":1,"at":0,"undo":"pending"}"#,
            // Not a UUID.
            #"{"id":"not-a-uuid","op":"archive","message_ids":["m-1"],"selected":1,"at":0,"undo":"undoable"}"#,
            // An empty identifier, which would build a request aimed at nothing.
            #"{"id":"\#(UUID().uuidString)","op":"archive","message_ids":[""],"selected":1,"at":0,"undo":"undoable"}"#,
            // The same message twice, which would ask about it twice and count it twice.
            #"{"id":"\#(UUID().uuidString)","op":"archive","message_ids":["m-1","m-1"],"selected":2,"at":0,"undo":"undoable"}"#,
            // More confirmed than were ever selected.
            #"{"id":"\#(UUID().uuidString)","op":"archive","message_ids":["m-1","m-2"],"selected":1,"at":0,"undo":"undoable"}"#,
            // A count no run in this app could have produced.
            #"{"id":"\#(UUID().uuidString)","op":"archive","message_ids":["m-1"],"selected":9999999,"at":0,"undo":"undoable"}"#,
        ]

        for entry in unusableEntries {
            let contents = #"{"v":3,"account":"sample.user@example.com","transactions":[\#(entry)]}"#
            try Data(contents.utf8).write(to: file)
            #expect(
                await store.transactions(for: account()).isEmpty,
                "A malformed entry survived the reader: \(entry)"
            )
            #expect(await store.latestUndoableTransaction(for: account()) == nil)
        }

        // A file mixing one unusable entry with one good one keeps the good one and only it.
        let mixed = #"{"v":3,"account":"sample.user@example.com","transactions":[\#(unusableEntries[0]),{"id":"\#(UUID().uuidString)","op":"archive","message_ids":["kept"],"selected":1,"at":0,"undo":"undoable"}]}"#
        try Data(mixed.utf8).write(to: file)
        let survivors = await store.transactions(for: account())
        #expect(survivors.count == 1)
        #expect(survivors.first?.messageID == MailMessageID("kept"))
    }

    @Test("A file written by the previous interval's schema is discarded rather than guessed at")
    func previousSchemaIsDiscarded() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)
        _ = await store.record(transaction())

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )

        // Version 1 held single-message records whose undo offers had already expired by design,
        // so there is nothing in one worth carrying forward.
        let version1 = """
            { "v": 1, "account": "sample.user@example.com", "records": [\
            { "id": "\(UUID().uuidString)", "op": "archive", "message_id": "m-1", "at": 0, "outcome": "confirmed" }] }
            """
        try Data(version1.utf8).write(to: file)

        #expect(await store.transactions(for: account()).isEmpty)
        #expect(await store.latestUndoableTransaction(for: account()) == nil)
    }

    // MARK: - History and retention

    @Test("The confirmed count round-trips, so a narrowed record keeps its history")
    func confirmedCountRoundTrips() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)

        // Ten archived out of ten selected, four since put back. What has to survive the file is
        // the *ten*: without it the six remaining identifiers read as an archive that only
        // managed six of ten, which never happened.
        let written = transaction(
            messageIDs: (1...6).map { "m-\($0)" },
            selectedCount: 10,
            confirmedCount: 10
        )
        #expect(await store.record(written) == .stored)

        let readBack = try #require(await store.transactions(for: account()).first)
        #expect(readBack == written)
        #expect(readBack.confirmedMessageCount == 10)
        #expect(readBack.restoredMessageCount == 4)
        #expect(readBack.outcome == .confirmed)
        #expect(readBack.activityStatus == .undoPartiallyCompleted)
    }

    @Test("A file from the previous schema is read, not discarded, so a live undo survives an update")
    func previousSchemaIsMigrated() async throws {
        // The opposite of what happens to version 1, and for a reason that did not apply then: a
        // version-2 file can hold an undo somebody is still relying on. Dropping it would mean
        // updating InboxSweep quietly took away the ability to put back what they archived ten
        // minutes earlier.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)
        _ = await store.record(transaction())

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )

        let identifier = UUID()
        let version2 = #"""
            {"v":2,"account":"sample.user@example.com","transactions":[\#
            {"id":"\#(identifier.uuidString)","op":"archive","message_ids":["a","b","c"],\#
            "selected":3,"at":0,"undo":"undoable"}]}
            """#
        try Data(version2.utf8).write(to: file)

        let migrated = try #require(await store.transactions(for: account()).first)
        #expect(migrated.id == identifier)
        #expect(migrated.succeededCount == 3)
        // No confirmed count in version 2, so the identifier count is what it means: exact for
        // every entry that has not been narrowed by a partial undo.
        #expect(migrated.confirmedMessageCount == 3)
        #expect(migrated.outcome == .confirmed)
        #expect(await store.latestUndoableTransaction(for: account())?.id == identifier)
    }

    @Test("A confirmed count outside the range any run could produce is dropped")
    func implausibleConfirmedCountsAreDropped() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)
        _ = await store.record(transaction())

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )

        let unusable = [
            // Fewer confirmed than are still undoable: the record contradicts itself.
            #"{"id":"\#(UUID().uuidString)","op":"archive","message_ids":["a","b"],"selected":4,"at":0,"undo":"undoable","confirmed":1}"#,
            // More confirmed than were ever selected.
            #"{"id":"\#(UUID().uuidString)","op":"archive","message_ids":["a"],"selected":2,"at":0,"undo":"undoable","confirmed":5}"#,
            // A count no run in this app could have produced.
            #"{"id":"\#(UUID().uuidString)","op":"archive","message_ids":["a"],"selected":2,"at":0,"undo":"undoable","confirmed":9999999}"#,
        ]

        for entry in unusable {
            let contents = #"{"v":3,"account":"sample.user@example.com","transactions":[\#(entry)]}"#
            try Data(contents.utf8).write(to: file)
            #expect(
                await store.transactions(for: account()).isEmpty,
                "A self-contradicting entry survived the reader: \(entry)"
            )
        }
    }

    @Test("Pruning never withdraws an undo the user could still be offered")
    func pruningKeepsTheLiveUndo() async throws {
        // Written first and never touched again, so every later entry is newer than it. A plain
        // newest-first prefix would eventually drop it, and dropping it is not a cosmetic loss:
        // the messages stay archived and the app silently stops being able to put them back.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)

        let undoable = transaction(messageIDs: ["still-archived"], secondsAfterEpoch: 0, undoState: .undoable)
        _ = await store.record(undoable)

        let limit = FileMutationTransactionStore.retainedTransactionLimit
        for index in 1...(limit + 15) {
            _ = await store.record(transaction(
                operation: .restoreToInbox,
                messageIDs: ["m-\(index)"],
                secondsAfterEpoch: Double(index),
                undoState: .notUndoable
            ))
        }

        let stored = await store.transactions(for: account())
        #expect(stored.count == limit, "The file grew past its bound")
        #expect(
            stored.contains { $0.id == undoable.id },
            "Retention pruned the transaction the undo offer names"
        )
        #expect(await store.latestUndoableTransaction(for: account())?.id == undoable.id)
    }

    @Test("A file that somehow grew past the bound is still read back bounded")
    func oversizedFilesArePrunedOnRead() async throws {
        // Pruning happens on the way out as well as on the way in, so a file written by another
        // build (or edited by hand) cannot put an unbounded history in front of the user.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)
        _ = await store.record(transaction())

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )

        let overflow = MailMutationHistory.entryLimit + 40
        let entries = (0..<overflow).map { index in
            #"{"id":"\#(UUID().uuidString)","op":"archive","message_ids":["m-\#(index)"],"selected":1,"at":\#(index),"undo":"superseded","confirmed":1}"#
        }
        let contents = #"{"v":3,"account":"sample.user@example.com","transactions":[\#(entries.joined(separator: ","))]}"#
        try Data(contents.utf8).write(to: file)

        #expect(await store.transactions(for: account()).count == MailMutationHistory.entryLimit)
    }

    @Test("A file whose entries name another account is read for neither")
    func fileHeaderDecidesTheAccount() async throws {
        // Entries carry no address of their own (the header names the account once) so the
        // property that matters is that reading for a *different* account returns nothing at all
        // rather than the header's entries relabelled.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationTransactionStore(directory: directory)
        _ = await store.record(transaction(messageIDs: ["private"], account: "first@example.com"))

        #expect(await store.transactions(for: account("second@example.net")).isEmpty)
        #expect(await store.latestUndoableTransaction(for: account("second@example.net")) == nil)
        #expect(await store.transactions(for: account("first@example.com")).count == 1)
    }

    @Test("A store with nowhere to write says so instead of failing silently")
    func reportsWhenItCannotWrite() async {
        // The distinction that matters: a record that cannot be written is reported, so a
        // confirmed archive is never presented as a failed one.
        let store = FileMutationTransactionStore(directory: nil, fileManager: FileManager())
        let unwritable = FileMutationTransactionStore(
            directory: URL(fileURLWithPath: "/dev/null/nowhere"),
            fileManager: FileManager()
        )

        let outcome = await unwritable.record(transaction())
        #expect(!outcome.isStored)
        #expect(outcome.warning?.isEmpty == false)
        // Nothing about the reason names a path, which would name the account's digest.
        #expect(outcome.warning?.contains("/") == false)
        _ = store
    }
}

import Foundation
import Testing
@testable import InboxSweep

/// The on-disk mutation record: what it holds, what it refuses to hold, and how it behaves when
/// the file is missing, unreadable, or somebody else's.
///
/// Writes to a temporary directory, never to the developer's own container.
@Suite("Mutation record store")
struct MutationRecordStoreTests {

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

    private func record(
        _ id: UUID = UUID(),
        operation: MailMutationOperation = .archive,
        messageID: String = "m-1",
        account address: String = "sample.user@example.com",
        secondsAfterEpoch: TimeInterval = 0,
        outcome: MailMutationRecord.Outcome = .confirmed
    ) -> MailMutationRecord {
        MailMutationRecord(
            id: id,
            operation: operation,
            messageID: MailMessageID(messageID),
            accountAddress: address,
            occurredAt: Self.epoch.addingTimeInterval(secondsAfterEpoch),
            outcome: outcome
        )
    }

    @Test("A record round-trips through the file")
    func roundTrips() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileMutationRecordStore(directory: directory)
        let written = record(operation: .archive, messageID: "m-42")

        #expect(await store.record(written) == .stored)

        let readBack = await store.records(for: account())
        #expect(readBack == [written])
    }

    @Test("Records come back newest first, however they were written")
    func ordersNewestFirst() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationRecordStore(directory: directory)

        _ = await store.record(record(messageID: "middle", secondsAfterEpoch: 60))
        _ = await store.record(record(messageID: "oldest", secondsAfterEpoch: 0))
        _ = await store.record(record(messageID: "newest", secondsAfterEpoch: 120))

        let ordered = await store.records(for: account()).map(\.messageID.rawValue)
        #expect(ordered == ["newest", "middle", "oldest"])
    }

    @Test("Writing the same operation twice replaces the record rather than adding one")
    func replacesByOperationID() async throws {
        // This is what makes a repeated completion callback safe: one logical mutation is one
        // record, whether the app wrote it once or three times.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationRecordStore(directory: directory)
        let id = UUID()

        _ = await store.record(record(id, outcome: .failed))
        _ = await store.record(record(id, outcome: .confirmed))
        _ = await store.record(record(id, outcome: .confirmed))

        let stored = await store.records(for: account())
        #expect(stored.count == 1)
        #expect(stored[0].outcome == .confirmed)
    }

    @Test("Only the most recent records are kept")
    func boundsTheFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationRecordStore(directory: directory)

        let limit = FileMutationRecordStore.retainedRecordLimit
        for index in 0..<(limit + 10) {
            _ = await store.record(record(messageID: "m-\(index)", secondsAfterEpoch: Double(index)))
        }

        let stored = await store.records(for: account())
        #expect(stored.count == limit, "The record file grew past its bound")
        // The newest survive; the oldest ten are gone.
        #expect(stored.first?.messageID == MailMessageID("m-\(limit + 9)"))
        #expect(!stored.contains { $0.messageID == MailMessageID("m-0") })
    }

    @Test("One account's records are never read back for another")
    func isolatesAccounts() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationRecordStore(directory: directory)

        _ = await store.record(record(account: "first@example.com"))
        #expect(await store.records(for: account("second@example.net")).isEmpty)

        // And writing for a second account leaves nothing of the first behind on disk.
        _ = await store.record(record(messageID: "m-2", account: "second@example.net"))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(files.count == 1, "A second account left the first account's file on disk")
        #expect(await store.records(for: account("first@example.com")).isEmpty)
    }

    @Test("Clearing removes the file")
    func clearing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationRecordStore(directory: directory)

        _ = await store.record(record())
        await store.clear(for: account())

        #expect(await store.records(for: account()).isEmpty)
    }

    @Test("A corrupt or future-version file is discarded rather than guessed at")
    func discardsUnusableFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationRecordStore(directory: directory)
        _ = await store.record(record())

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )

        try Data("{ not json at all".utf8).write(to: file)
        #expect(await store.records(for: account()).isEmpty)

        let future = """
            { "v": 999, "account": "sample.user@example.com", "records": [] }
            """
        try Data(future.utf8).write(to: file)
        #expect(await store.records(for: account()).isEmpty)
    }

    @Test("The file is owner-only and excluded from backups")
    func fileIsProtected() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationRecordStore(directory: directory)
        _ = await store.record(record())

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )

        let permissions = try #require(
            try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.posixPermissions] as? NSNumber
        )
        #expect(permissions.int16Value == 0o600)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test("The file names messages and never describes them")
    func fileHoldsNoMail() async throws {
        // The record exists for undo and for the user's own visibility. Copying a subject or a
        // sender in would put the same mailbox content in a second file for no gain — the cache
        // already holds it for every message in the loaded window.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMutationRecordStore(directory: directory)
        _ = await store.record(record(messageID: "18f2c9a"))

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

    @Test("A store with nowhere to write says so instead of failing silently")
    func reportsWhenItCannotWrite() async {
        // The distinction that matters: a record that cannot be written is reported, so a
        // confirmed archive is never presented as a failed one.
        let store = FileMutationRecordStore(directory: nil, fileManager: FileManager())
        let unwritable = FileMutationRecordStore(
            directory: URL(fileURLWithPath: "/dev/null/nowhere"),
            fileManager: FileManager()
        )

        let outcome = await unwritable.record(record())
        #expect(!outcome.isStored)
        #expect(outcome.warning?.isEmpty == false)
        // Nothing about the reason names a path, which would name the account's digest.
        #expect(outcome.warning?.contains("/") == false)
        _ = store
    }
}

import Foundation
import Testing
@testable import InboxSweep

/// The on-disk cache, exercised against real files in a temporary directory.
///
/// Uses the actual ``FileInboxCacheStore`` rather than a stand-in, because most of what could
/// go wrong here — a format that does not round-trip, a file from an older build, a leftover
/// file from another account — only goes wrong once bytes are involved.
@Suite("Inbox cache store")
struct InboxCacheStoreTests {

    // MARK: - Fixtures

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func account(_ address: String = "sample.user@example.com") -> MailAccount {
        MailAccount(
            emailAddress: EmailAddressParser.parse("Sample User <\(address)>"),
            providerDisplayName: "Gmail",
            providerMessageCount: 4_210
        )
    }

    private func messages() -> [MailMessage] {
        [
            MailMessage(
                id: MailMessageID("m-1"),
                threadID: MailThreadID("t-1"),
                sender: EmailAddressParser.parse("The Daily Digest <newsletter@example.com>"),
                subject: "Issue 138",
                receivedAt: Self.epoch,
                labels: [.inbox, .unread, .categoryPromotions],
                hasListUnsubscribeHeader: true
            ),
            MailMessage(
                id: MailMessageID("m-2"),
                sender: EmailAddressParser.parse("newsletter@example.com"),
                subject: nil,
                receivedAt: Self.epoch.addingTimeInterval(-86_400),
                labels: [.inbox, .other("Label_7")]
            ),
            MailMessage(
                id: MailMessageID("m-3"),
                sender: EmailAddressParser.parse("(no sender)"),
                subject: "Delivery status notification",
                receivedAt: .distantPast,
                labels: [.inbox]
            ),
        ]
    }

    private func inbox(
        account: MailAccount? = nil,
        nextPageToken: MailPageToken? = MailPageToken("page-2")
    ) -> CachedInbox {
        let messages = messages()
        return CachedInbox(
            account: account ?? self.account(),
            messages: messages,
            senders: SenderAggregator.aggregate(messages),
            nextPageToken: nextPageToken,
            savedAt: Self.epoch
        )
    }

    /// Runs `body` against a store rooted in a temporary directory, removed afterwards.
    private func withTemporaryStore(
        _ body: (FileInboxCacheStore, URL) async throws -> Void
    ) async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "InboxSweepCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await body(FileInboxCacheStore(directory: directory), directory)
    }

    // MARK: - Round trip

    @Test("A saved window comes back exactly as it went in")
    func roundTripsAWindow() async throws {
        try await withTemporaryStore { store, _ in
            let saved = inbox()
            await store.save(saved)

            let loaded = try #require(await store.load(for: account()))
            #expect(loaded == saved)
        }
    }

    @Test("Labels the app does not model survive the round trip")
    func roundTripsUnmodelledLabels() async throws {
        try await withTemporaryStore { store, _ in
            await store.save(inbox())
            let loaded = try #require(await store.load(for: account()))

            let restored = try #require(loaded.messages.first { $0.id == MailMessageID("m-2") })
            #expect(restored.labels.contains(.other("Label_7")))
        }
    }

    @Test("The unknown-sender group survives the round trip as one group")
    func roundTripsUnknownSenders() async throws {
        try await withTemporaryStore { store, _ in
            await store.save(inbox())
            let loaded = try #require(await store.load(for: account()))

            let unknown = try #require(loaded.senders.first { $0.id == EmailAddress.unknownGroupingKey })
            #expect(!unknown.sender.hasAddress)
            #expect(unknown.messageCount == 1)
        }
    }

    @Test("Observations survive the round trip")
    func roundTripsObservations() async throws {
        try await withTemporaryStore { store, _ in
            await store.save(inbox())
            let loaded = try #require(await store.load(for: account()))

            let newsletter = try #require(loaded.senders.first { $0.id == "newsletter@example.com" })
            #expect(newsletter.categoryLabels == [.categoryPromotions])
            #expect(newsletter.listUnsubscribeCount == 1)
            #expect(newsletter.averageIntervalBetweenLoadedMessages == 86_400)
        }
    }

    @Test("The page cursor survives, so pagination continues after a relaunch")
    func roundTripsPageToken() async throws {
        try await withTemporaryStore { store, _ in
            await store.save(inbox(nextPageToken: MailPageToken("page-2")))
            #expect(await store.load(for: account())?.nextPageToken == MailPageToken("page-2"))
        }
    }

    @Test("A window with no further pages comes back with no cursor")
    func roundTripsExhaustedWindow() async throws {
        try await withTemporaryStore { store, _ in
            await store.save(inbox(nextPageToken: nil))
            #expect(await store.load(for: account())?.nextPageToken == nil)
        }
    }

    // MARK: - Nothing to load

    @Test("An empty cache is nothing to load, not a failure")
    func loadsNothingWhenEmpty() async throws {
        try await withTemporaryStore { store, _ in
            #expect(await store.load(for: account()) == nil)
        }
    }

    @Test("Clearing removes the stored window")
    func clearsAWindow() async throws {
        try await withTemporaryStore { store, directory in
            await store.save(inbox())
            await store.clear(for: account())

            #expect(await store.load(for: account()) == nil)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(remaining.filter { $0.hasSuffix(".json") }.isEmpty)
        }
    }

    // MARK: - Migration and damaged files

    @Test("A file written by a different schema version is discarded, not guessed at")
    func discardsOtherSchemaVersions() async throws {
        try await withTemporaryStore { store, directory in
            await store.save(inbox())
            let file = try #require(try Self.cacheFile(in: directory))

            // Simulate a file left behind by a build whose format has since changed.
            var record = try InboxCacheDTO.makeDecoder()
                .decode(InboxCacheDTO.Record.self, from: Data(contentsOf: file))
            record.version = InboxCacheDTO.schemaVersion + 1
            try InboxCacheDTO.makeEncoder().encode(record).write(to: file)

            #expect(await store.load(for: account()) == nil)
        }
    }

    @Test("A file from before the schema was versioned is discarded")
    func discardsUnversionedFiles() async throws {
        try await withTemporaryStore { store, directory in
            await store.save(inbox())
            let file = try #require(try Self.cacheFile(in: directory))
            try Data(#"{"account":"sample.user@example.com","messages":[]}"#.utf8).write(to: file)

            #expect(await store.load(for: account()) == nil)
        }
    }

    @Test("A truncated or corrupt file is discarded rather than crashing the launch")
    func discardsCorruptFiles() async throws {
        try await withTemporaryStore { store, directory in
            await store.save(inbox())
            let file = try #require(try Self.cacheFile(in: directory))
            try Data("{ this is not json".utf8).write(to: file)

            #expect(await store.load(for: account()) == nil)
        }
    }

    @Test("A window belonging to another account is never handed over")
    func refusesAnotherAccountsWindow() async throws {
        try await withTemporaryStore { store, _ in
            await store.save(inbox())
            #expect(await store.load(for: account("someone.else@example.org")) == nil)
        }
    }

    @Test("Only one account's window is kept on disk at a time")
    func keepsOneAccountAtATime() async throws {
        try await withTemporaryStore { store, directory in
            await store.save(inbox())
            await store.save(inbox(account: account("someone.else@example.org")))

            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".json") }
            #expect(files.count == 1)
            #expect(await store.load(for: account()) == nil)
            #expect(await store.load(for: account("someone.else@example.org")) != nil)
        }
    }

    // MARK: - What the file contains

    @Test("The cache file is readable only by its owner")
    func restrictsFilePermissions() async throws {
        try await withTemporaryStore { store, directory in
            await store.save(inbox())
            let file = try #require(try Self.cacheFile(in: directory))

            let permissions = try FileManager.default
                .attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.int16Value == 0o600)
        }
    }

    @Test("The filename does not spell out the account address")
    func doesNotNameTheFileAfterTheAccount() async throws {
        try await withTemporaryStore { store, directory in
            await store.save(inbox())
            let file = try #require(try Self.cacheFile(in: directory))

            #expect(!file.lastPathComponent.contains("sample.user"))
            #expect(!file.lastPathComponent.contains("example.com"))
        }
    }

    @Test("Nothing token-shaped is written to the file")
    func storesNoCredentials() async throws {
        try await withTemporaryStore { store, directory in
            await store.save(inbox())
            let file = try #require(try Self.cacheFile(in: directory))
            let contents = try String(contentsOf: file, encoding: .utf8).lowercased()

            for forbidden in ["refresh_token", "access_token", "bearer", "authorization", "client_id"] {
                #expect(!contents.contains(forbidden), "The cache file mentioned \(forbidden)")
            }
        }
    }

    @Test("The file holds message metadata and nowhere to put a body")
    func storesMetadataOnly() async throws {
        try await withTemporaryStore { store, directory in
            await store.save(inbox())
            let file = try #require(try Self.cacheFile(in: directory))
            let contents = try String(contentsOf: file, encoding: .utf8).lowercased()

            #expect(contents.contains("issue 138"), "Subjects are metadata and are expected")
            for forbidden in ["\"body\"", "\"snippet\"", "\"payload\"", "\"attachment", "\"raw\""] {
                #expect(!contents.contains(forbidden), "The cache file carried \(forbidden)")
            }
        }
    }

    // MARK: - Derived data

    @Test("Summaries that no longer add up to their messages are detected")
    func detectsDivergedSummaries() {
        let messages = messages()
        let matching = CachedInbox(
            account: account(),
            messages: messages,
            senders: SenderAggregator.aggregate(messages),
            nextPageToken: nil,
            savedAt: Self.epoch
        )
        let diverged = CachedInbox(
            account: account(),
            messages: messages,
            senders: SenderAggregator.aggregate(Array(messages.dropLast())),
            nextPageToken: nil,
            savedAt: Self.epoch
        )

        #expect(matching.summariesMatchMessages)
        #expect(!diverged.summariesMatchMessages)
    }

    // MARK: - Label tokens

    @Test("Every modelled label has a distinct, stable token")
    func labelTokensAreDistinct() {
        let labels: [MailLabel] = [
            .inbox, .unread, .starred, .important, .sent, .draft, .spam, .trash,
            .categoryPromotions, .categorySocial, .categoryUpdates, .categoryForums, .categoryPersonal,
        ]
        let tokens = labels.map(MailLabelToken.string(for:))

        #expect(Set(tokens).count == labels.count)
        for label in labels {
            #expect(MailLabelToken.label(for: MailLabelToken.string(for: label)) == label)
        }
    }

    @Test("An unmodelled label cannot be confused with a modelled one")
    func unmodelledLabelsStayDistinct() {
        // `.other("inbox")` is a provider label that happens to be spelled like ours; it must
        // not decode as the app's own `.inbox`.
        let token = MailLabelToken.string(for: .other("inbox"))

        #expect(token != MailLabelToken.string(for: .inbox))
        #expect(MailLabelToken.label(for: token) == .other("inbox"))
    }

    private static func cacheFile(in directory: URL) throws -> URL? {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" }
    }
}

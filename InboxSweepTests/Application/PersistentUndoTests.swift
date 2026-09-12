import Foundation
import Testing
@testable import InboxSweep

/// The durable transaction and the undo it makes possible, including across a relaunch.
///
/// "Across a relaunch" is exercised the only way it honestly can be in a test: by building a
/// second ``InboxSessionModel`` over the same store, which is precisely what the next launch of
/// the app does. Nothing is carried over in memory between the two halves of those cases.
@MainActor
@Suite("Persistent transactions and undo")
struct PersistentUndoTests {

    nonisolated static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func message(_ id: String, daysAgo: Double = 0) -> MailMessage {
        MailMessage(
            id: MailMessageID(id),
            sender: EmailAddressParser.parse("newsletter@example.com"),
            subject: "Subject \(id)",
            receivedAt: Self.epoch.addingTimeInterval(-daysAgo * 86_400),
            labels: [.inbox]
        )
    }

    private func makeSession(
        messages: [MailMessage],
        archiver: StubMessageArchiver,
        records: any MailMutationRecording,
        restorable: MailConnection = .disconnected
    ) async -> InboxSessionModel {
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            restorable: restorable,
            archiver: archiver
        )
        let session = InboxSessionModel(
            provider: provider,
            mutationRecords: records,
            fetchRequest: MailFetchRequest(limit: max(messages.count, 1)),
            now: { Self.epoch }
        )
        if case .connected = restorable {
            await session.restore().value
        } else {
            await session.connect().value
        }
        return session
    }

    private func selection(
        _ session: InboxSessionModel,
        _ messages: [MailMessage],
        _ ids: [String]
    ) throws -> ArchiveSelectionSnapshot {
        try #require(session.makeArchiveSelection(
            forSenderKey: messages[0].sender.groupingKey,
            messageIDs: ids.map { MailMessageID($0) }
        ))
    }

    // MARK: - What gets written

    @Test("A successful set writes one transaction naming every confirmed message")
    func transactionNamesTheConfirmedSet() async throws {
        let messages = (1...8).map { message("m-\($0)", daysAgo: Double($0)) }
        let records = EphemeralMutationRecordStore()
        let session = await makeSession(messages: messages, archiver: StubMessageArchiver(), records: records)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2", "m-3", "m-4"])).value

        let stored = await records.transactions(for: .testAccount)
        #expect(stored.count == 1)
        let transaction = try #require(stored.first)
        #expect(transaction.operation == .archive)
        #expect(transaction.accountAddress == MailAccount.testAccount.emailAddress.address)
        #expect(Set(transaction.succeededMessageIDs.map(\.rawValue)) == ["m-1", "m-2", "m-3", "m-4"])
        #expect(transaction.selectedMessageCount == 4)
        #expect(transaction.outcome == .confirmed)
        #expect(transaction.isUndoable)
        #expect(transaction.occurredAt == Self.epoch)
    }

    @Test("A partial run writes a transaction for the successful subset only")
    func partialRunWritesASubsetTransaction() async throws {
        let messages = (1...10).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        archiver.setBehavior(.fails(.rateLimited), forMessage: MailMessageID("m-2"))
        archiver.setBehavior(.fails(.rateLimited), forMessage: MailMessageID("m-5"))
        let records = EphemeralMutationRecordStore()
        let session = await makeSession(messages: messages, archiver: archiver, records: records)

        await session.archiveSelection(try selection(session, messages, (1...6).map { "m-\($0)" })).value

        let transaction = try #require(await records.transactions(for: .testAccount).first)
        // Four identifiers for four archived messages. The two that failed are counted, not
        // named: there is nothing to undo about a message that never changed.
        #expect(Set(transaction.succeededMessageIDs.map(\.rawValue)) == ["m-1", "m-3", "m-4", "m-6"])
        #expect(transaction.selectedMessageCount == 6)
        #expect(transaction.failedMessageCount == 2)
        #expect(transaction.outcome == .partiallyConfirmed)
        #expect(transaction.isUndoable, "A partially successful archive offered no undo for what did change")
    }

    @Test("A run that confirmed nothing is written down, and is not undoable")
    func failedRunIsRecordedButNotUndoable() async throws {
        let messages = (1...4).map { message("m-\($0)", daysAgo: Double($0)) }
        let records = EphemeralMutationRecordStore()
        let session = await makeSession(
            messages: messages,
            archiver: StubMessageArchiver(archiveBehavior: .fails(.rateLimited)),
            records: records
        )

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2"])).value

        let transaction = try #require(await records.transactions(for: .testAccount).first)
        #expect(transaction.succeededMessageIDs.isEmpty)
        #expect(transaction.outcome == .failed)
        #expect(!transaction.isUndoable)
        #expect(session.undoableArchive == nil)
    }

    // MARK: - Relaunch

    @Test("A relaunch offers the undo the previous launch created")
    func relaunchRestoresTheOffer() async throws {
        let messages = (1...10).map { message("m-\($0)", daysAgo: Double($0)) }
        let records = EphemeralMutationRecordStore()

        // Launch one: archive four and quit.
        let first = await makeSession(messages: messages, archiver: StubMessageArchiver(), records: records)
        await first.archiveSelection(try selection(first, messages, ["m-1", "m-2", "m-3", "m-4"])).value
        let transactionID = try #require(first.undoableArchive?.id)

        // Launch two: a brand-new session over the same store, restoring a stored sign-in.
        let archiver = StubMessageArchiver()
        let remaining = messages.filter { !["m-1", "m-2", "m-3", "m-4"].contains($0.id.rawValue) }
        let second = await makeSession(
            messages: remaining,
            archiver: archiver,
            records: records,
            restorable: .connected(.testAccount)
        )

        let offered = try #require(second.undoableArchive, "The undo offer did not survive the relaunch")
        #expect(offered.id == transactionID)
        #expect(Set(offered.succeededMessageIDs.map(\.rawValue)) == ["m-1", "m-2", "m-3", "m-4"])
        // Restoring an offer is a read of a local file. It sends nothing.
        #expect(archiver.allRequests.isEmpty, "Restoring the undo offer contacted the provider")
    }

    @Test("A relaunch undo restores exactly the messages that transaction archived")
    func relaunchThenUndo() async throws {
        let messages = (1...10).map { message("m-\($0)", daysAgo: Double($0)) }
        let records = EphemeralMutationRecordStore()

        let first = await makeSession(messages: messages, archiver: StubMessageArchiver(), records: records)
        await first.archiveSelection(try selection(first, messages, ["m-2", "m-5", "m-9"])).value

        let archiver = StubMessageArchiver()
        let remaining = messages.filter { !["m-2", "m-5", "m-9"].contains($0.id.rawValue) }
        let second = await makeSession(
            messages: remaining,
            archiver: archiver,
            records: records,
            restorable: .connected(.testAccount)
        )

        await second.undoLastArchive().value

        // Three requests, naming the three messages the transaction confirmed, and no others.
        // Nothing is inferred into the set, not the rest of the sender, not the rest of a thread.
        #expect(Set(archiver.undoRequests.map(\.messageID.rawValue)) == ["m-2", "m-5", "m-9"])
        #expect(archiver.archiveRequests.isEmpty)
        #expect(second.mutationActivity?.didSucceed == true)
        #expect(second.undoableArchive == nil, "The offer survived a complete undo")

        let history = await records.transactions(for: .testAccount)
        #expect(history.first { $0.operation == .archive }?.undoState == .undone)
    }

    @Test("A transaction for another account is never offered")
    func accountIsolation() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: Double($0)) }
        let records = EphemeralMutationRecordStore()

        // Somebody else's archive, stored under their address.
        _ = await records.record(MailMutationTransaction(
            id: UUID(),
            operation: .archive,
            accountAddress: "somebody.else@example.net",
            succeededMessageIDs: [MailMessageID("theirs-1"), MailMessageID("theirs-2")],
            selectedMessageCount: 2,
            occurredAt: Self.epoch,
            undoState: .undoable
        ))

        let session = await makeSession(
            messages: messages,
            archiver: StubMessageArchiver(),
            records: records,
            restorable: .connected(.testAccount)
        )

        #expect(session.undoableArchive == nil, "Another account's transaction was offered as this account's undo")
        #expect(await session.mutationHistory().isEmpty)
    }

    @Test("An undo is refused when the connected account is no longer the one that archived")
    func undoRefusesAnAccountMismatch() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: Double($0)) }
        let records = EphemeralMutationRecordStore()
        let archiver = StubMessageArchiver()
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            archiver: archiver
        )
        let session = InboxSessionModel(
            provider: provider,
            mutationRecords: records,
            fetchRequest: MailFetchRequest(limit: 5),
            now: { Self.epoch }
        )
        await session.connect().value

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2"])).value
        #expect(session.undoableArchive != nil)
        let archiveRequestCount = archiver.archiveRequests.count

        // The adapter is now authenticated as somebody else: a re-authorization that landed in
        // a second Google account is all it takes.
        await provider.setConnection(.connected(MailAccount(
            emailAddress: EmailAddressParser.parse("somebody.else@example.com"),
            providerDisplayName: "Stub"
        )))

        await session.undoLastArchive().value

        #expect(session.mutationActivity?.error == .accountChanged)
        #expect(archiver.undoRequests.isEmpty, "An undo went out for a stale account")
        #expect(archiver.archiveRequests.count == archiveRequestCount)
    }

    @Test("Losing the archive permission withdraws the offer rather than failing when pressed")
    func offerRequiresAStandingGrant() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: Double($0)) }
        let records = EphemeralMutationRecordStore()

        let first = await makeSession(messages: messages, archiver: StubMessageArchiver(), records: records)
        await first.archiveSelection(try selection(first, messages, ["m-1", "m-2"])).value

        // Next launch, the grant no longer covers archiving: withdrawn from the Google Account.
        let downgraded = StubMessageArchiver(capability: .requiresAdditionalPermission)
        let second = await makeSession(
            messages: messages.filter { !["m-1", "m-2"].contains($0.id.rawValue) },
            archiver: downgraded,
            records: records,
            restorable: .connected(.testAccount)
        )

        #expect(second.undoableArchive == nil, "An undo was offered that the grant could not honour")
        // The transaction itself is still there; it is the *offer* that is withheld.
        #expect(await records.transactions(for: .testAccount).first?.isUndoable == true)
    }

    // MARK: - Partial undo

    @Test("An undo that half works restores what it can and keeps offering the rest")
    func partialUndoNarrowsTheOffer() async throws {
        let messages = (1...8).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        let records = EphemeralMutationRecordStore()
        let session = await makeSession(messages: messages, archiver: archiver, records: records)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2", "m-3", "m-4"])).value
        #expect(try #require(session.state.snapshot).loadedMessageCount == 4)

        // Two of the four refuse to come back.
        archiver.setBehavior(.fails(.rateLimited), forMessage: MailMessageID("m-2"))
        archiver.setBehavior(.fails(.rateLimited), forMessage: MailMessageID("m-3"))

        await session.undoLastArchive().value

        let activity = try #require(session.mutationActivity)
        #expect(activity.confirmedCount == 2)
        #expect(activity.failedCount == 2)
        #expect(activity.isPartialSuccess)

        // Local state matches per message: two back in the Inbox, two still archived.
        let inbox = session.loadedMessages(forSenderKey: messages[0].sender.groupingKey)
        #expect(Set(inbox.map(\.id.rawValue)) == ["m-1", "m-4", "m-5", "m-6", "m-7", "m-8"])

        // The offer narrows to exactly what is still archived, and is never re-widened to
        // include the two already back.
        let remaining = try #require(session.undoableArchive)
        #expect(Set(remaining.succeededMessageIDs.map(\.rawValue)) == ["m-2", "m-3"])
        #expect(remaining.isUndoable)
    }

    @Test("A second undo after a partial one only re-asks about what is still archived")
    func repeatedUndoIsIdempotentOnWhatRemains() async throws {
        let messages = (1...6).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        let records = EphemeralMutationRecordStore()
        let session = await makeSession(messages: messages, archiver: archiver, records: records)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2", "m-3"])).value
        archiver.setBehavior(.fails(.rateLimited), forMessage: MailMessageID("m-3"))
        await session.undoLastArchive().value
        #expect(archiver.undoRequests.count == 3)

        // The rate limit lifts, and the user presses Undo again.
        archiver.setBehavior(.succeeds, forMessage: MailMessageID("m-3"))
        await session.undoLastArchive().value

        // One further request, for the one message still archived, not another three.
        #expect(archiver.undoRequests.count == 4, "A repeated undo re-asked about messages already restored")
        #expect(archiver.undoRequests.suffix(1).map(\.messageID) == [MailMessageID("m-3")])
        #expect(session.undoableArchive == nil)
        #expect(try #require(session.state.snapshot).loadedMessageCount == 6)

        // And a third press does nothing at all, because the offer is gone.
        await session.undoLastArchive().value
        #expect(archiver.undoRequests.count == 4)
    }

    @Test("An undo that restores nothing leaves the offer exactly as it was")
    func completelyFailedUndoKeepsTheOffer() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        let records = EphemeralMutationRecordStore()
        let session = await makeSession(messages: messages, archiver: archiver, records: records)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2"])).value
        archiver.setUndoBehavior(.fails(.rateLimited))

        await session.undoLastArchive().value

        #expect(session.mutationActivity?.error == .rateLimited)
        #expect(session.mutationActivity?.changedAnything == false)
        // The archive really happened and the messages are really still archived, so the offer
        // stands unchanged.
        let offer = try #require(session.undoableArchive)
        #expect(Set(offer.succeededMessageIDs.map(\.rawValue)) == ["m-1", "m-2"])
        #expect(try #require(session.state.snapshot).loadedMessageCount == 3)
    }

    // MARK: - Lifecycle

    @Test("A new archive supersedes the previous offer, and the history keeps both")
    func newArchiveSupersedesTheOffer() async throws {
        let messages = (1...8).map { message("m-\($0)", daysAgo: Double($0)) }
        let records = EphemeralMutationRecordStore()
        let session = await makeSession(messages: messages, archiver: StubMessageArchiver(), records: records)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2"])).value
        let firstID = try #require(session.undoableArchive?.id)

        await session.archiveSelection(try selection(session, messages, ["m-3", "m-4", "m-5"])).value
        let secondID = try #require(session.undoableArchive?.id)

        #expect(firstID != secondID)
        #expect(session.undoableArchive?.succeededCount == 3)

        let history = await records.transactions(for: .testAccount)
        #expect(history.count == 2, "Superseding deleted the audit history instead of marking it")
        #expect(history.count(where: \.isUndoable) == 1, "Two transactions both claimed to be undoable")
        #expect(history.first { $0.id == firstID }?.undoState == .superseded)

        // And the undo acts on the second set only. The first two messages stay archived.
        #expect(session.undoableArchive?.succeededMessageIDs.map(\.rawValue).sorted() == ["m-3", "m-4", "m-5"])
    }

    @Test("An archive that confirmed nothing leaves an existing offer standing")
    func aFailedArchiveDoesNotSupersede() async throws {
        let messages = (1...8).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        let records = EphemeralMutationRecordStore()
        let session = await makeSession(messages: messages, archiver: archiver, records: records)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2"])).value
        let firstID = try #require(session.undoableArchive?.id)

        archiver.setArchiveBehavior(.fails(.rateLimited))
        await session.archiveSelection(try selection(session, messages, ["m-3", "m-4"])).value

        // Nothing new is archived, so nothing new is undoable, and the earlier archive is still
        // a true statement about two messages that are still out of the Inbox.
        #expect(session.undoableArchive?.id == firstID, "A failed archive withdrew an unrelated undo offer")
        #expect(await records.transactions(for: .testAccount).count(where: \.isUndoable) == 1)
    }

    @Test("Disconnecting removes the transactions and with them the offer")
    func disconnectClearsEverything() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: Double($0)) }
        let records = EphemeralMutationRecordStore()
        let session = await makeSession(messages: messages, archiver: StubMessageArchiver(), records: records)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2"])).value
        #expect(session.undoableArchive != nil)

        await session.disconnect().value

        #expect(session.undoableArchive == nil)
        #expect(await records.transactions(for: .testAccount).isEmpty)
    }
}

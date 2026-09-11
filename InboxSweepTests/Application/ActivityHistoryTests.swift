import Foundation
import Testing
@testable import InboxSweep

/// The Activity screen's data, end to end through the session: what appears in it, what never
/// does, and what it is allowed to reach.
///
/// The archive mechanics themselves are `MessageSetArchiveTests` and `PersistentUndoTests`. These
/// cases are about the *history* those mechanics leave behind — and about the two claims the
/// screen makes that nothing else in the app checks: that it lists only InboxSweep's own changes,
/// and that reading it sends nothing anywhere.
@MainActor
@Suite("Activity history")
struct ActivityHistoryTests {

    nonisolated static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func message(_ id: String, daysAgo: Double = 0, labels: Set<MailLabel> = [.inbox]) -> MailMessage {
        MailMessage(
            id: MailMessageID(id),
            sender: EmailAddressParser.parse("newsletter@example.com"),
            subject: "Subject \(id)",
            receivedAt: Self.epoch.addingTimeInterval(-daysAgo * 86_400),
            labels: labels
        )
    }

    /// A connected session.
    ///
    /// `clock` is injectable because ordering is part of what these cases check, and a session
    /// pinned to one instant writes two archives with identical timestamps — at which point the
    /// history's deterministic tiebreak decides their order rather than the order they ran in.
    /// Any case that performs more than one mutation advances it between them.
    private func makeSession(
        messages: [MailMessage],
        archiver: StubMessageArchiver? = StubMessageArchiver(),
        records: any MailMutationRecording = EphemeralMutationRecordStore(),
        account: MailAccount = .testAccount,
        clock: AdvanceableClock = AdvanceableClock(ActivityHistoryTests.epoch)
    ) async -> InboxSessionModel {
        let provider = StubMailProvider(
            connect: .succeeds(account),
            fetch: .pages([MailMessagePage(messages: messages)]),
            archiver: archiver
        )
        let session = InboxSessionModel(
            provider: provider,
            mutationRecords: records,
            fetchRequest: MailFetchRequest(limit: max(messages.count, 1)),
            now: { clock.now }
        )
        await session.connect().value
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

    // MARK: - Empty and populated

    @Test("A session that has changed nothing has an empty history")
    func emptyHistory() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: Double($0)) }
        let session = await makeSession(messages: messages)

        // Loading, sorting, previewing, and reviewing are all reads. None of them is a change,
        // so none of them belongs in a list of changes.
        _ = session.cleanupPlan(for: [
            CleanupPlanRequest(
                senderKey: messages[0].sender.groupingKey,
                action: .archiveMessagesOlderThan(days: 1)
            ),
        ])
        _ = session.reviewedMessages(forSenderKey: messages[0].sender.groupingKey)
        await session.reload().value

        #expect(await session.activityHistory().isEmpty)
    }

    @Test("A signed-out session has no history to show, whatever is on disk")
    func signedOutHistoryIsEmpty() async throws {
        let records = EphemeralMutationRecordStore()
        _ = await records.record(MailMutationTransaction(
            id: UUID(),
            operation: .archive,
            accountAddress: MailAccount.testAccount.emailAddress.address,
            succeededMessageIDs: [MailMessageID("m-1")],
            selectedMessageCount: 1,
            occurredAt: Self.epoch,
            undoState: .undoable
        ))

        let session = InboxSessionModel(
            provider: StubMailProvider(archiver: StubMessageArchiver()),
            mutationRecords: records
        )

        // Never connected. History belongs to an account, and there is no account.
        #expect(await session.activityHistory().isEmpty)
    }

    @Test("An archive appears in Activity, saying what it did")
    func archiveAppears() async throws {
        let messages = (1...6).map { message("m-\($0)", daysAgo: Double($0)) }
        let session = await makeSession(messages: messages)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2", "m-3"])).value

        let history = await session.activityHistory()
        let entry = try #require(history.first)

        #expect(history.count == 1)
        // "from one sender" because the loaded window can still describe all three and they
        // agree — see `ActivityEntry.cameFromOneSender`. It is a statement about these three
        // messages, not about the sender.
        #expect(entry.title == "Archived 3 messages from one sender")
        #expect(entry.confirmedCount == 3)
        #expect(entry.selectedCount == 3)
        #expect(entry.unchangedCount == 0)
        #expect(entry.status == .undoAvailable)
        #expect(entry.isUndoable)
    }

    @Test("A partial archive is presented as partial")
    func partialArchiveAppears() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        archiver.setBehavior(.fails(.messageNoLongerAvailable), forMessage: MailMessageID("m-2"))
        archiver.setBehavior(.fails(.messageNoLongerAvailable), forMessage: MailMessageID("m-4"))
        let session = await makeSession(messages: messages, archiver: archiver)

        await session.archiveSelection(
            try selection(session, messages, ["m-1", "m-2", "m-3", "m-4", "m-5"])
        ).value

        let entry = try #require(await session.activityHistory().first)
        #expect(entry.title == "Archived 3 of 5 messages from one sender")
        #expect(entry.isPartial)
        #expect(entry.unchangedSummary == "2 messages couldn't be archived")
        #expect(entry.isUndoable, "The three that were archived can still be put back")
    }

    @Test("Changes are listed newest first")
    func historyIsReverseChronological() async throws {
        let messages = (1...6).map { message("m-\($0)", daysAgo: Double($0)) }
        let clock = AdvanceableClock(Self.epoch)
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            archiver: StubMessageArchiver()
        )
        let session = InboxSessionModel(
            provider: provider,
            fetchRequest: MailFetchRequest(limit: 6),
            now: { clock.now }
        )
        await session.connect().value

        await session.archiveSelection(try selection(session, messages, ["m-1"])).value
        clock.advance(by: 600)
        await session.archiveSelection(try selection(session, messages, ["m-2"])).value
        clock.advance(by: 600)
        await session.archiveSelection(try selection(session, messages, ["m-3"])).value

        let history = await session.activityHistory()
        #expect(history.count == 3)
        #expect(history.map(\.occurredAt) == history.map(\.occurredAt).sorted(by: >))
        #expect(history[0].occurredAt == Self.epoch.addingTimeInterval(1_200))
    }

    // MARK: - Undo, superseding, and what stays actionable

    @Test("Only the current undo offer is undoable from Activity")
    func onlyTheLatestArchiveIsUndoable() async throws {
        // The property the screen could most easily get wrong: an older archive is *visible*
        // here in a way it never was before, and being visible must not make it actionable.
        let messages = (1...6).map { message("m-\($0)", daysAgo: Double($0)) }
        let clock = AdvanceableClock(Self.epoch)
        let session = await makeSession(messages: messages, clock: clock)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2"])).value
        clock.advance(by: 600)
        await session.archiveSelection(try selection(session, messages, ["m-3"])).value

        let history = await session.activityHistory()
        #expect(history.count == 2)
        #expect(history[0].isUndoable, "The most recent archive should still be undoable")
        #expect(!history[1].isUndoable, "A superseded archive became undoable by being listed")
        #expect(history[1].status == .undoSuperseded)
        #expect(history[1].title == "Archived 2 messages from one sender", "Superseding rewrote what the archive did")
    }

    @Test("Undoing from Activity uses the existing path and the transaction's own messages")
    func undoFromActivity() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        let clock = AdvanceableClock(Self.epoch)
        let session = await makeSession(messages: messages, archiver: archiver, clock: clock)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2"])).value
        let before = try #require(await session.activityHistory().first)
        #expect(before.isUndoable)

        clock.advance(by: 600)
        // The Activity screen's button calls exactly this — there is no second undo entry point.
        await session.undoLastArchive().value

        // The undo named the transaction's confirmed messages and nothing else.
        #expect(archiver.undoRequests.map(\.messageID) == [MailMessageID("m-1"), MailMessageID("m-2")])

        let history = await session.activityHistory()
        #expect(history.count == 2, "The undo should be a change of its own")
        #expect(history[0].operation == .restoreToInbox)
        #expect(history[0].title == "Put 2 messages back in your Inbox")

        let archive = try #require(history.first { $0.operation == .archive })
        #expect(archive.status == .undoCompleted)
        #expect(archive.title == "Archived 2 messages", "The undo rewrote what the archive did")
        #expect(!archive.isUndoable, "An undone archive stayed undoable")
    }

    @Test("A partly-successful undo leaves the archive partly undone and still offered")
    func partialUndoFromActivity() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        let clock = AdvanceableClock(Self.epoch)
        let session = await makeSession(messages: messages, archiver: archiver, clock: clock)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2", "m-3", "m-4"])).value

        clock.advance(by: 600)
        archiver.setBehavior(.fails(.rateLimited), forMessage: MailMessageID("m-3"))
        archiver.setBehavior(.fails(.rateLimited), forMessage: MailMessageID("m-4"))
        await session.undoLastArchive().value

        let history = await session.activityHistory()
        let archive = try #require(history.first { $0.operation == .archive })

        #expect(archive.title == "Archived 4 messages", "A partial undo was read back as a partial archive")
        #expect(archive.status == .undoPartiallyCompleted)
        #expect(archive.restoredCount == 2)
        #expect(archive.transaction.succeededCount == 2, "The remaining offer should name only what is still archived")
        #expect(archive.isUndoable, "The two still archived can still be put back")

        let undo = try #require(history.first { $0.operation == .restoreToInbox })
        #expect(undo.title == "Put 2 of 4 messages back in your Inbox")
        #expect(undo.unchangedSummary == "2 messages couldn't be put back")
    }

    @Test("An archive that confirmed nothing is recorded, and offers no undo")
    func failedArchiveAppearsWithoutAnOffer() async throws {
        let messages = (1...3).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver(archiveBehavior: .fails(.rateLimited))
        let session = await makeSession(messages: messages, archiver: archiver)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2"])).value

        let entry = try #require(await session.activityHistory().first)
        #expect(entry.title == "No messages were archived")
        #expect(entry.status == .nothingChanged)
        #expect(!entry.isUndoable)
        #expect(entry.confirmedCount == 0)
    }

    // MARK: - Cache metadata

    @Test("Message details are resolved from the loaded window, and are never required")
    func resolvesMetadataFromTheWindow() async throws {
        let messages = (1...4).map { message("m-\($0)", daysAgo: Double($0)) }
        let session = await makeSession(messages: messages)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2"])).value

        let entry = try #require(await session.activityHistory().first)
        #expect(entry.hasResolvedMetadata)
        #expect(entry.resolvedMessages.map(\.id) == [MailMessageID("m-1"), MailMessageID("m-2")])
        #expect(entry.resolvedMessages.compactMap(\.subject) == ["Subject m-1", "Subject m-2"])
        #expect(entry.metadataFallback == nil)
    }

    @Test("A change whose messages have left the window still reads correctly")
    func degradesWhenTheWindowNoLongerCoversTheMessages() async throws {
        // An archive from long enough ago that the loaded window no longer describes it. The
        // counts are still exact, because they never came from the mailbox in the first place.
        let messages = (1...3).map { message("m-\($0)", daysAgo: Double($0)) }
        let records = EphemeralMutationRecordStore()
        _ = await records.record(MailMutationTransaction(
            id: UUID(),
            operation: .archive,
            accountAddress: MailAccount.testAccount.emailAddress.address,
            succeededMessageIDs: [MailMessageID("long-gone-1"), MailMessageID("long-gone-2")],
            selectedMessageCount: 2,
            occurredAt: Self.epoch.addingTimeInterval(-86_400 * 90),
            undoState: .superseded
        ))
        let session = await makeSession(messages: messages, records: records)

        let entry = try #require(await session.activityHistory().first)
        #expect(!entry.hasResolvedMetadata)
        #expect(entry.title == "Archived 2 messages", "The counts should not depend on the cache")
        #expect(entry.status == .undoSuperseded)
        #expect(entry.metadataFallback?.isEmpty == false)
    }

    // MARK: - Account isolation

    @Test("One account's Activity is never shown under another")
    func historyIsScopedToTheConnectedAccount() async throws {
        let other = MailAccount(
            emailAddress: EmailAddressParser.parse("someone.else@example.net"),
            providerDisplayName: "Gmail"
        )
        let records = EphemeralMutationRecordStore()
        _ = await records.record(MailMutationTransaction(
            id: UUID(),
            operation: .archive,
            accountAddress: other.emailAddress.address,
            succeededMessageIDs: [MailMessageID("theirs-1"), MailMessageID("theirs-2")],
            selectedMessageCount: 2,
            occurredAt: Self.epoch,
            undoState: .undoable
        ))

        let messages = (1...3).map { message("m-\($0)", daysAgo: Double($0)) }
        let session = await makeSession(messages: messages, records: records)

        #expect(await session.activityHistory().isEmpty, "Another account's changes were listed")
        #expect(session.undoableArchive == nil, "Another account's undo was offered")

        // And its messages are not resolvable through this session either, even by asking
        // directly with that account's transaction.
        let theirs = await records.transactions(for: other)
        #expect(session.resolvedMessages(for: try #require(theirs.first)).isEmpty)
        #expect(!session.canUndo(try #require(theirs.first)))
    }

    @Test("Signing out deletes this account's Activity")
    func disconnectDeletesHistory() async throws {
        // The deliberate privacy semantics, unchanged from the previous interval and now worth
        // stating as a test: disconnecting is the user saying they are done, and a list of what
        // was done to a mailbox the app can no longer even look at is not worth keeping for them.
        let messages = (1...4).map { message("m-\($0)", daysAgo: Double($0)) }
        let records = EphemeralMutationRecordStore()
        let session = await makeSession(messages: messages, records: records)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2"])).value
        #expect(await session.activityHistory().count == 1)

        await session.disconnect().value

        #expect(await records.transactions(for: .testAccount).isEmpty, "History survived a sign-out")
        #expect(await session.activityHistory().isEmpty)
        #expect(session.undoableArchive == nil)
    }

    // MARK: - The boundary between InboxSweep's changes and Gmail's

    @Test("Mail that left the inbox outside InboxSweep produces no Activity entry")
    func externalChangesAreReconciledAndNeverFabricated() async throws {
        // The distinction the screen exists to keep: InboxSweep reconciles the mailbox it can
        // see, and writes down only what it did itself. A message somebody archived in Gmail is
        // gone from the next window — and that is a fact about their mailbox, not a change this
        // app can claim.
        let messages = (1...4).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            archiver: archiver
        )
        let session = InboxSessionModel(
            provider: provider,
            fetchRequest: MailFetchRequest(limit: 4),
            now: { Self.epoch }
        )
        await session.connect().value
        #expect(await session.activityHistory().isEmpty)

        // The mailbox moves underneath: two messages are no longer in the inbox, and one that
        // was archived has come back. Nothing about it went through this app.
        await provider.setFetchBehavior(.pages([MailMessagePage(messages: [
            message("m-1", daysAgo: 1, labels: []),
            message("m-2", daysAgo: 2, labels: []),
            message("m-3", daysAgo: 3),
            message("m-4", daysAgo: 4),
            message("m-5", daysAgo: 5),
        ])]))
        await session.reload().value

        let snapshot = try #require(session.state.snapshot)
        #expect(snapshot.loadedMessageCount == 3, "The reload should reconcile what Gmail reports")
        #expect(await session.activityHistory().isEmpty, "A Gmail-side change was fabricated into Activity")
        #expect(archiver.allRequests.isEmpty)
    }

    // MARK: - Reading Activity changes nothing

    @Test("Opening Activity, listing it, and opening a row send nothing to a provider")
    func readingActivityPerformsNoProviderCall() async throws {
        let messages = (1...6).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            archiver: archiver
        )
        let session = InboxSessionModel(
            provider: provider,
            fetchRequest: MailFetchRequest(limit: 6),
            now: { Self.epoch }
        )
        await session.connect().value
        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2"])).value

        let fetchesBefore = await provider.fetchCallCount
        let connectsBefore = await provider.connectCallCount
        let writesBefore = archiver.allRequests.count

        // Everything the screen does: read the history, read every row's detail, resolve every
        // row's metadata, and ask every row whether it is undoable.
        for _ in 0..<3 {
            let history = await session.activityHistory()
            for entry in history {
                _ = entry.title
                _ = entry.statusSummary
                _ = entry.unchangedSummary
                _ = entry.explanation
                _ = entry.metadataFallback
                _ = session.resolvedMessages(for: entry.transaction)
                _ = session.canUndo(entry.transaction)
            }
        }

        #expect(await provider.fetchCallCount == fetchesBefore, "Reading Activity fetched")
        #expect(await provider.connectCallCount == connectsBefore, "Reading Activity re-authorized")
        #expect(await provider.disconnectCallCount == 0)
        #expect(archiver.allRequests.count == writesBefore, "Reading Activity reached the mutation boundary")
        #expect(archiver.capabilityCallCount >= 0)
    }
}

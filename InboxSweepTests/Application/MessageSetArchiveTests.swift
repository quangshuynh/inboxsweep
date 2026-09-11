import Foundation
import Testing
@testable import InboxSweep

/// Archiving a set: what goes out, what comes back, and — mostly — what a run that half worked
/// does to everything else.
///
/// The partial-failure cases are the bulk of this suite on purpose. Sending twelve `POST`s
/// correctly is the easy part. The hard part is that a set of twelve where four are refused has
/// to leave eight messages archived, four messages in the Inbox, a sender count that says 4, a
/// recomputed proposal, a cache file that matches, an undo offer naming eight identifiers and not
/// twelve, and a screen that says "8 archived, 4 failed" rather than "failed" — and none of that
/// can be checked by inspection.
@MainActor
@Suite("Archiving a set of messages")
struct MessageSetArchiveTests {

    nonisolated static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func message(
        _ id: String,
        from: String = "newsletter@example.com",
        daysAgo: Double = 0,
        labels: Set<MailLabel> = [.inbox]
    ) -> MailMessage {
        MailMessage(
            id: MailMessageID(id),
            sender: EmailAddressParser.parse(from),
            subject: "Subject \(id)",
            receivedAt: Self.epoch.addingTimeInterval(-daysAgo * 86_400),
            labels: labels
        )
    }

    private func makeSession(
        messages: [MailMessage],
        archiver: StubMessageArchiver = StubMessageArchiver(),
        cache: any InboxCacheStoring = EphemeralInboxCache(),
        records: any MailMutationRecording = EphemeralMutationRecordStore()
    ) async -> (InboxSessionModel, StubMailProvider, StubMessageArchiver) {
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            archiver: archiver
        )
        let session = InboxSessionModel(
            provider: provider,
            cache: cache,
            mutationRecords: records,
            fetchRequest: MailFetchRequest(limit: max(messages.count, 1)),
            now: { Self.epoch }
        )
        await session.connect().value
        return (session, provider, archiver)
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

    // MARK: - All succeed

    @Test("A set of ten sends ten requests, one per message, and archives all ten")
    func allSucceed() async throws {
        let messages = (1...14).map { message("m-\($0)", daysAgo: Double($0)) }
        let (session, _, archiver) = await makeSession(messages: messages)
        let chosen = (1...10).map { "m-\($0)" }

        await session.archiveSelection(try selection(session, messages, chosen)).value

        let requests = archiver.archiveRequests
        #expect(requests.count == 10, "A set of ten produced \(requests.count) requests")
        #expect(Set(requests.map(\.messageID.rawValue)) == Set(chosen))
        #expect(requests.allSatisfy { $0.accountAddress == MailAccount.testAccount.emailAddress.address })
        // One logical mutation, however many requests it took.
        #expect(Set(requests.map(\.operationID)).count == 1)

        let activity = try #require(session.mutationActivity)
        #expect(activity.didSucceed)
        #expect(activity.confirmedCount == 10)
        #expect(activity.failedCount == 0)

        // Only the ten left; the other four are untouched.
        let remaining = session.loadedMessages(forSenderKey: messages[0].sender.groupingKey)
        #expect(remaining.count == 4)
        #expect(Set(remaining.map(\.id.rawValue)) == Set((11...14).map { "m-\($0)" }))
    }

    @Test("A set of one behaves exactly like the single-message archive it generalizes")
    func oneSucceeds() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: Double($0)) }
        let (session, _, archiver) = await makeSession(messages: messages)

        await session.archiveSelection(try selection(session, messages, ["m-3"])).value

        #expect(archiver.archiveRequests.map(\.messageID) == [MailMessageID("m-3")])
        #expect(session.mutationActivity?.didSucceed == true)
        #expect(session.undoableArchive?.messageID == MailMessageID("m-3"))
        #expect(try #require(session.state.snapshot).loadedMessageCount == 4)
    }

    // MARK: - Partial failure

    @Test("Eight of ten archived is reported as eight archived, not as a failure")
    func partialSuccessIsReportedPerMessage() async throws {
        let messages = (1...12).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        // Two messages Gmail refuses for reasons that say nothing about the other eight.
        archiver.setBehavior(.fails(.rateLimited), forMessage: MailMessageID("m-4"))
        archiver.setBehavior(.fails(.messageNoLongerAvailable), forMessage: MailMessageID("m-7"))
        let (session, _, _) = await makeSession(messages: messages, archiver: archiver)
        let chosen = (1...10).map { "m-\($0)" }

        await session.archiveSelection(try selection(session, messages, chosen)).value

        let activity = try #require(session.mutationActivity)
        #expect(activity.selectedCount == 10)
        #expect(activity.confirmedCount == 8)
        #expect(activity.failedCount == 2)
        #expect(activity.isPartialSuccess)
        #expect(!activity.didSucceed, "A partial run claimed complete success")
        #expect(activity.changedAnything, "A partial run claimed nothing happened")

        // The failures are identifiable without exposing anything from Gmail's response body.
        let receipt = try #require(activity.receipt)
        let failedIDs = Set(receipt.failures.map(\.messageID.rawValue))
        #expect(failedIDs == ["m-4", "m-7"])
        #expect(receipt.failures.first { $0.messageID == MailMessageID("m-4") }?.outcome.error == .rateLimited)

        // Local state matches, message by message: eight left the Inbox and two did not.
        let remaining = session.loadedMessages(forSenderKey: messages[0].sender.groupingKey)
        #expect(remaining.count == 4)
        #expect(Set(remaining.map(\.id.rawValue)) == ["m-4", "m-7", "m-11", "m-12"])
    }

    @Test("A failure in the middle of a run does not roll back the successes before it")
    func successesSurviveALaterFailure() async throws {
        let messages = (1...6).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        archiver.setBehavior(.fails(.network(reason: "The connection dropped.")), forMessage: MailMessageID("m-5"))
        let (session, _, _) = await makeSession(messages: messages, archiver: archiver)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2", "m-3", "m-4", "m-5"])).value

        // Nothing is un-archived to tidy up the result. Those four messages really did leave the
        // Inbox, and putting them back because a fifth failed would be the app rewriting history
        // it does not own — and would be four more writes nobody asked for.
        #expect(session.mutationActivity?.confirmedCount == 4)
        #expect(archiver.undoRequests.isEmpty, "A failure triggered an automatic rollback")
        #expect(try #require(session.state.snapshot).loadedMessageCount == 2)
    }

    @Test("Every message failing leaves the mailbox and the window exactly as they were")
    func allFail() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver(archiveBehavior: .fails(.rateLimited))
        let (session, _, _) = await makeSession(messages: messages, archiver: archiver)
        let before = try #require(session.state.snapshot)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2", "m-3"])).value

        let activity = try #require(session.mutationActivity)
        #expect(activity.confirmedCount == 0)
        #expect(activity.failedCount == 3)
        #expect(!activity.changedAnything)
        // Only when nothing was confirmed does a set collapse to a single error to lead with.
        #expect(activity.error == .rateLimited)

        #expect(try #require(session.state.snapshot).loadedMessageCount == before.loadedMessageCount)
        #expect(session.undoableArchive == nil, "A run that changed nothing offered an undo")
    }

    @Test("A session-wide failure stops the run instead of sending doomed requests")
    func nonRetryableSessionFailureEndsTheRun() async throws {
        // A withdrawn grant is true of every message at once. Sending the remaining nine
        // requests would be nine pointless writes against somebody's quota, and nine failures to
        // explain instead of one.
        let messages = (1...12).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver(archiveBehavior: .fails(.authorizationExpired))
        let (session, _, _) = await makeSession(messages: messages, archiver: archiver)

        await session.archiveSelection(try selection(session, messages, (1...10).map { "m-\($0)" })).value

        #expect(archiver.archiveRequests.count == 1, "The run kept going after the grant was gone")

        let activity = try #require(session.mutationActivity)
        #expect(activity.failedCount == 1)
        #expect(activity.notAttemptedCount == 9)
        #expect(activity.confirmedCount == 0)

        // A message that was never asked about is knowably unchanged, and is reported as such
        // rather than as a failure.
        let receipt = try #require(activity.receipt)
        #expect(receipt.notAttempted.allSatisfy { $0.outcome.error == .authorizationExpired })
        #expect(receipt.notAttempted.allSatisfy { !$0.outcome.wasAttempted })
    }

    @Test("A per-message failure does not stop the run, because it says nothing about the rest")
    func retryableFailureDoesNotEndTheRun() async throws {
        let messages = (1...8).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        archiver.setBehavior(.fails(.rateLimited), forMessage: MailMessageID("m-1"))
        archiver.setBehavior(.fails(.messageNoLongerAvailable), forMessage: MailMessageID("m-2"))
        let (session, _, _) = await makeSession(messages: messages, archiver: archiver)

        await session.archiveSelection(try selection(session, messages, (1...6).map { "m-\($0)" })).value

        #expect(archiver.archiveRequests.count == 6, "A per-message failure abandoned the rest of the set")
        #expect(session.mutationActivity?.confirmedCount == 4)
        #expect(session.mutationActivity?.notAttemptedCount == 0)

        // Only the retryable one is offered again; a message Gmail no longer has is not, because
        // repeating that request is certain to fail the same way.
        let retryable = try #require(session.mutationActivity).retryableMessageIDs
        #expect(retryable == [MailMessageID("m-1")])
    }

    // MARK: - Execution shape

    @Test("A set is sent one message at a time, never fanned out")
    func executionIsStrictlySequential() async throws {
        let messages = (1...20).map { message("m-\($0)", daysAgo: Double($0)) }
        let (session, _, archiver) = await makeSession(messages: messages)

        await session.archiveSelection(try selection(session, messages, (1...20).map { "m-\($0)" })).value

        #expect(archiver.archiveRequests.count == 20)
        #expect(
            archiver.peakConcurrentRequests == 1,
            "\(archiver.peakConcurrentRequests) requests were in flight at once — the run fanned out"
        )
    }

    @Test("A duplicated identifier is one request and one outcome, not two")
    func duplicatesCollapse() async throws {
        let messages = (1...4).map { message("m-\($0)", daysAgo: Double($0)) }
        let (session, _, archiver) = await makeSession(messages: messages)

        // The UI selects into a Set, so this cannot arrive from the table — but the boundary is
        // where it has to be impossible, not where it happens to be unlikely.
        let frozen = try #require(MailArchiveSelection(
            messageIDs: [MailMessageID("m-1"), MailMessageID("m-1"), MailMessageID("m-2")],
            accountAddress: MailAccount.testAccount.emailAddress.address
        ))
        let receipt = await MessageSetMutator(archiver: archiver).perform(.archive, frozen)

        #expect(archiver.archiveRequests.count == 2, "One message was archived twice")
        #expect(receipt.selectedCount == 2)
        #expect(receipt.confirmedCount == 2)
        _ = session
    }

    @Test("Stopping a run leaves the confirmed messages archived and sends nothing further")
    func cancellationIsHonest() async throws {
        let messages = (1...10).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        // The fourth message never answers, so the run is sitting on it when Stop is pressed.
        archiver.setBehavior(.stalls, forMessage: MailMessageID("m-4"))
        let (session, _, _) = await makeSession(messages: messages, archiver: archiver)

        let running = session.archiveSelection(try selection(session, messages, (1...10).map { "m-\($0)" }))
        await archiver.waitForRequests(atLeast: 4)

        session.cancelMutation()
        await running.value

        let activity = try #require(session.mutationActivity)
        // Three confirmed, the stalled one abandoned, and the six after it never sent. The count
        // of requests is the proof the promise was kept.
        #expect(activity.confirmedCount == 3)
        #expect(archiver.archiveRequests.count == 4, "Requests kept going out after the run was stopped")
        #expect(activity.notAttemptedCount == 6)

        // What was confirmed stays confirmed. Cancelling is not an undo.
        #expect(try #require(session.state.snapshot).loadedMessageCount == 7)
        #expect(session.undoableArchive?.succeededCount == 3)
    }

    @Test("Confirming the same frozen set twice archives it once")
    func duplicateConfirmationIsRefused() async throws {
        let messages = (1...6).map { message("m-\($0)", daysAgo: Double($0)) }
        let records = EphemeralMutationRecordStore()
        let (session, _, archiver) = await makeSession(messages: messages, records: records)
        let frozen = try selection(session, messages, ["m-1", "m-2", "m-3"])

        // Both presses land before the first finishes — the case a disabled button does not
        // cover, because the disabling happens a render later.
        let first = session.archiveSelection(frozen)
        let second = session.archiveSelection(frozen)
        await first.value
        await second.value

        // And once more after it has finished, with the sheet still on screen showing the same
        // confirmed set. This is the press the in-flight guard cannot catch.
        await session.archiveSelection(frozen).value

        #expect(archiver.archiveRequests.count == 3, "A repeated confirmation archived more than once")
        let history = await records.transactions(for: .testAccount)
        #expect(history.count == 1, "A repeated confirmation wrote more than one transaction")
    }

    @Test("A set frozen before a reload is refused whole rather than narrowed")
    func staleSetIsRefusedWhole() async throws {
        let messages = (1...6).map { message("m-\($0)", daysAgo: Double($0)) }
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            archiver: StubMessageArchiver()
        )
        let session = InboxSessionModel(provider: provider, fetchRequest: MailFetchRequest(limit: 6), now: { Self.epoch })
        await session.connect().value
        let frozen = try selection(session, messages, ["m-1", "m-2", "m-3"])

        await provider.setFetchBehavior(.pages([MailMessagePage(
            messages: messages.filter { $0.id != MailMessageID("m-2") }
        )]))
        await session.reload().value

        await session.archiveSelection(frozen).value

        #expect(session.mutationActivity?.error == .selectionChanged)
        #expect(session.mutationActivity?.receipt == nil, "A stale set was partly executed")
        let archiver = try #require(await provider.messageArchiver as? StubMessageArchiver)
        #expect(archiver.allRequests.isEmpty, "A stale set reached Gmail")
    }

    @Test("An account that changed between confirming and executing is refused")
    func accountChangeIsRefusedBeforeAnythingIsSent() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: Double($0)) }
        let (session, provider, archiver) = await makeSession(messages: messages)
        let frozen = try selection(session, messages, ["m-1", "m-2", "m-3"])

        // The window still belongs to the account it was read for; the adapter is authenticated
        // as somebody else. Asked of the provider, because only the provider knows.
        await provider.setConnection(.connected(MailAccount(
            emailAddress: EmailAddressParser.parse("somebody.else@example.com"),
            providerDisplayName: "Stub"
        )))

        await session.archiveSelection(frozen).value

        #expect(session.mutationActivity?.error == .accountChanged)
        #expect(archiver.allRequests.isEmpty, "A set went out for a stale account")
    }

    // MARK: - Reconciliation

    @Test("A partial run recomputes the summary, the proposal, and the preview over what is left")
    func partialRunRecomputesEverythingDerived() async throws {
        let messages = ProposalFixtures.promotionalSender(count: 18)
        let archiver = StubMessageArchiver()
        archiver.setBehavior(.fails(.rateLimited), forMessage: messages[2].id)
        let (session, _, _) = await makeSession(messages: messages, archiver: archiver)
        let key = messages[0].sender.groupingKey

        let planBefore = session.cleanupPlan(for: [CleanupPlanRequest(senderKey: key, action: .keepNewest(count: 3))])
        #expect(planBefore.window.loadedMessageCount == 18)

        let chosen = messages.prefix(6).map(\.id.rawValue)
        await session.archiveSelection(try selection(session, Array(messages), Array(chosen))).value

        // Five confirmed, one refused: eighteen minus five.
        #expect(session.mutationActivity?.confirmedCount == 5)

        let after = try #require(session.state.snapshot)
        #expect(after.loadedMessageCount == 13)
        #expect(after.senders[0].messageCount == 13)

        let planAfter = session.cleanupPlan(for: [CleanupPlanRequest(senderKey: key, action: .keepNewest(count: 3))])
        #expect(planAfter.window.loadedMessageCount == 13, "The dry run still counted archived messages")

        let proposal = try #require(session.proposal(forSenderKey: key))
        #expect(proposal.loadedMessageCount == 13, "The proposal was carried over rather than recomputed")

        // And the refused message is still reviewable, because it is still in the Inbox.
        #expect(session.reviewedMessages(forSenderKey: key).contains { $0.id == messages[2].id })
    }

    @Test("The cache is rewritten with what Gmail confirmed, not with what was asked for")
    func cacheMatchesTheRemoteOutcome() async throws {
        let cache = RecordingInboxCache()
        let messages = (1...8).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        archiver.setBehavior(.fails(.rateLimited), forMessage: MailMessageID("m-3"))
        let (session, _, _) = await makeSession(messages: messages, archiver: archiver, cache: cache)

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2", "m-3", "m-4"])).value

        let saved = try #require(await cache.lastSaved)
        #expect(saved.messages.count == 5)
        #expect(saved.messages.contains { $0.id == MailMessageID("m-3") }, "A refused message was cached as archived")
        #expect(Set(saved.messages.map(\.id.rawValue)) == ["m-3", "m-5", "m-6", "m-7", "m-8"])
        #expect(saved.summariesMatchMessages)
    }

    @Test("A refresh from the provider converges on the same state a partial run produced")
    func refreshConvergesOnThePartialOutcome() async throws {
        let messages = (1...8).map { message("m-\($0)", daysAgo: Double($0)) }
        let archiver = StubMessageArchiver()
        archiver.setBehavior(.fails(.rateLimited), forMessage: MailMessageID("m-3"))
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            archiver: archiver
        )
        let session = InboxSessionModel(provider: provider, fetchRequest: MailFetchRequest(limit: 8), now: { Self.epoch })
        await session.connect().value

        await session.archiveSelection(try selection(session, messages, ["m-1", "m-2", "m-3", "m-4"])).value
        #expect(try #require(session.state.snapshot).loadedMessageCount == 5)

        // Gmail's Inbox list no longer returns the three that were archived, and still returns
        // the one it refused — which is exactly what local state already says.
        let archived: Set<MailMessageID> = [MailMessageID("m-1"), MailMessageID("m-2"), MailMessageID("m-4")]
        await provider.setFetchBehavior(.pages([MailMessagePage(
            messages: messages.filter { !archived.contains($0.id) }
        )]))
        await session.reload().value

        let refreshed = try #require(session.state.snapshot)
        #expect(refreshed.loadedMessageCount == 5)
        #expect(session.loadedMessages(forSenderKey: messages[0].sender.groupingKey)
            .contains { $0.id == MailMessageID("m-3") })
    }
}

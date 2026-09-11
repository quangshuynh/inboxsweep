import Foundation
import Testing
@testable import InboxSweep

/// The session's half of archiving: what it refuses, what it sends, and — mostly — what it does
/// to everything derived from the loaded window once Gmail says yes.
///
/// The reconciliation cases are the bulk of this suite on purpose. Sending one `POST` correctly
/// is the easy part; the hard part is that a sender count, a proposal, a protection verdict, a
/// dry-run membership, a cache file, and the next refresh all have to agree afterwards, and
/// there is no way to check that by inspection.
@MainActor
@Suite("Archiving messages")
struct MessageArchiveTests {

    nonisolated static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func message(
        _ id: String,
        from: String = "newsletter@example.com",
        hours: Double = 0,
        labels: Set<MailLabel> = [.inbox]
    ) -> MailMessage {
        MailMessage(
            id: MailMessageID(id),
            sender: EmailAddressParser.parse(from),
            subject: "Subject \(id)",
            receivedAt: Self.epoch.addingTimeInterval(hours * 3600),
            labels: labels
        )
    }

    /// A connected session over `messages`, with a granted archiver.
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

    // MARK: - Capability

    @Test("A session whose provider cannot write offers nothing, rather than a disabled button")
    func noArchiverMeansNoOffer() async {
        let (session, _, _) = await makeSession(messages: [message("m-1")], archiver: StubMessageArchiver())
        let readOnly = InboxSessionModel(
            provider: StubMailProvider(fetch: .pages([MailMessagePage(messages: [message("m-1")])])),
            fetchRequest: MailFetchRequest(limit: 1)
        )
        await readOnly.connect().value

        #expect(session.canOfferArchiving)
        #expect(!readOnly.canOfferArchiving)
        #expect(readOnly.archiveCapability == .unsupported)
    }

    @Test("A grant without the archive permission offers the upgrade, not the archive")
    func missingPermissionOffersAnUpgrade() async {
        let archiver = StubMessageArchiver(capability: .requiresAdditionalPermission)
        let (session, _, _) = await makeSession(messages: [message("m-1")], archiver: archiver)

        #expect(session.canOfferArchiving, "The provider can write; only the grant is short")
        #expect(session.archiveCapability == .requiresAdditionalPermission)
        #expect(!session.canArchive(messageID: MailMessageID("m-1")))

        let capabilityQueriesBefore = archiver.capabilityCallCount
        await session.requestArchivePermission().value

        #expect(session.archiveCapability == .granted)
        #expect(session.canArchive(messageID: MailMessageID("m-1")))
        #expect(archiver.upgradeCallCount == 1)
        #expect(session.notice == nil)

        // Re-derived from the provider rather than taken from what `authorizeArchiving()`
        // returned: the provider holds the grant, so only it can answer what the next archive
        // attempt will actually find.
        #expect(
            archiver.capabilityCallCount > capabilityQueriesBefore,
            "The session trusted the upgrade's return value instead of re-asking the provider"
        )
    }

    @Test("A granted permission republishes the window, so the screen offering it updates")
    func grantingRepublishesTheWindow() async throws {
        // The defect this pins down was found on a real account: granting the permission moved
        // only `archiveCapability`, and the sheet that offers the action draws everything else
        // from the snapshot — so it went on offering to request a permission the user had
        // already granted until it was closed and reopened.
        let archiver = StubMessageArchiver(capability: .requiresAdditionalPermission)
        let (session, _, _) = await makeSession(
            messages: [message("m-1"), message("m-2")],
            archiver: archiver
        )
        let before = try #require(session.state.snapshot)

        await session.requestArchivePermission().value

        // A fresh snapshot, carrying the same mail: the permission changed, the window did not.
        let after = try #require(session.state.snapshot)
        #expect(after.loadedMessageCount == before.loadedMessageCount)
        #expect(after.senders == before.senders)
        #expect(session.canArchive(messageID: MailMessageID("m-1")))
    }

    @Test("A declined permission also re-asks the provider rather than assuming")
    func decliningAlsoRepublishes() async throws {
        let archiver = StubMessageArchiver(
            capability: .requiresAdditionalPermission,
            upgradeResult: .failure(.permissionDeclined)
        )
        let (session, _, _) = await makeSession(messages: [message("m-1")], archiver: archiver)

        let capabilityQueriesBefore = archiver.capabilityCallCount
        await session.requestArchivePermission().value

        #expect(archiver.capabilityCallCount > capabilityQueriesBefore)
        #expect(session.archiveCapability == .requiresAdditionalPermission)
        #expect(session.state.snapshot != nil, "A declined upgrade lost the loaded window")
    }

    @Test("A declined upgrade explains itself and leaves the rest of the session working")
    func declinedUpgradeIsExplained() async throws {
        let archiver = StubMessageArchiver(
            capability: .requiresAdditionalPermission,
            upgradeResult: .failure(.permissionDeclined)
        )
        let (session, _, _) = await makeSession(
            messages: [message("m-1"), message("m-2")],
            archiver: archiver
        )

        await session.requestArchivePermission().value

        #expect(session.archiveCapability == .requiresAdditionalPermission)
        #expect(session.notice == SessionNotice.archivePermissionDeclined)
        // Reading is untouched.
        let snapshot = try #require(session.state.snapshot)
        #expect(snapshot.loadedMessageCount == 2)
    }

    @Test("Archiving without permission is refused without reaching the boundary")
    func archiveWithoutPermissionIsRefused() async throws {
        let archiver = StubMessageArchiver(capability: .requiresAdditionalPermission)
        let (session, _, _) = await makeSession(messages: [message("m-1")], archiver: archiver)

        await session.archiveMessage(MailMessageID("m-1")).value

        #expect(session.mutationActivity?.error == .permissionRequired)
        #expect(archiver.allRequests.isEmpty)
    }

    // MARK: - Archiving

    @Test("Archiving one message sends one request naming that message and that account")
    func archivesExactlyTheChosenMessage() async throws {
        let messages = (1...5).map { message("m-\($0)", hours: Double($0)) }
        let (session, _, archiver) = await makeSession(messages: messages)

        await session.archiveMessage(MailMessageID("m-3")).value

        let requests = archiver.archiveRequests
        #expect(requests.count == 1)
        #expect(requests.first?.messageID == MailMessageID("m-3"))
        #expect(requests.first?.accountAddress == MailAccount.testAccount.emailAddress.address)
        #expect(archiver.undoRequests.isEmpty)
        #expect(session.mutationActivity?.didSucceed == true)
    }

    @Test("A double submission produces one request and one record")
    func duplicateSubmissionIsRefused() async throws {
        let messages = (1...3).map { message("m-\($0)") }
        let archiver = StubMessageArchiver()
        let records = EphemeralMutationRecordStore()
        let (session, _, _) = await makeSession(messages: messages, archiver: archiver, records: records)

        // Both presses land before the first has finished — which is the case a disabled button
        // does not cover, because the disabling happens a render later.
        let first = session.archiveMessage(MailMessageID("m-1"))
        let second = session.archiveMessage(MailMessageID("m-1"))
        await first.value
        await second.value

        #expect(archiver.allRequests.count == 1, "A double click archived twice")
        #expect(await records.transactions(for: .testAccount).count == 1, "A double click wrote two records")
    }

    @Test("A second archive is refused while the first is still in flight")
    func concurrentMutationsAreRefused() async throws {
        let archiver = StubMessageArchiver(archiveBehavior: .stalls)
        let (session, _, _) = await makeSession(
            messages: [message("m-1"), message("m-2")],
            archiver: archiver
        )

        let running = session.archiveMessage(MailMessageID("m-1"))

        // Wait until the first request is genuinely with the archiver, so this tests the guard
        // rather than the scheduler happening not to have started the task yet.
        for _ in 0..<1_000 where archiver.archiveRequests.isEmpty {
            await Task.yield()
        }
        #expect(archiver.archiveRequests.count == 1)
        #expect(session.isMutating)

        await session.archiveMessage(MailMessageID("m-2")).value

        #expect(archiver.archiveRequests.count == 1, "A second message was archived mid-flight")
        #expect(archiver.archiveRequests.first?.messageID == MailMessageID("m-1"))

        running.cancel()
        await running.value
    }

    @Test("A message that is not in the loaded window is refused, and nothing is sent")
    func staleMessageIsRefused() async throws {
        let (session, _, archiver) = await makeSession(messages: [message("m-1")])

        await session.archiveMessage(MailMessageID("m-gone")).value

        #expect(session.mutationActivity?.error == .messageNotInLoadedWindow)
        #expect(archiver.allRequests.isEmpty)
    }

    @Test("An account that changed between choosing and confirming is refused")
    func staleAccountIsRefused() async throws {
        let (session, provider, archiver) = await makeSession(messages: [message("m-1")])

        // The window on screen belongs to the account it was read for. The adapter is now
        // authenticated as somebody else — a re-authorization that landed in a second Google
        // account is all it takes.
        let other = MailAccount(
            emailAddress: EmailAddressParser.parse("somebody.else@example.com"),
            providerDisplayName: "Stub"
        )
        await provider.setConnection(.connected(other))

        await session.archiveMessage(MailMessageID("m-1")).value

        #expect(session.mutationActivity?.error == .accountChanged)
        #expect(archiver.allRequests.isEmpty, "A mutation went out for a stale account")
        #expect(session.undoableArchive == nil)
    }

    @Test("A remote failure does not fake a local success")
    func remoteFailureChangesNothingLocally() async throws {
        let archiver = StubMessageArchiver(archiveBehavior: .fails(.network(reason: "The connection dropped.")))
        let (session, _, _) = await makeSession(
            messages: [message("m-1"), message("m-2"), message("m-3")],
            archiver: archiver
        )
        let before = try #require(session.state.snapshot)

        await session.archiveMessage(MailMessageID("m-1")).value

        #expect(session.mutationActivity?.error == .network(reason: "The connection dropped."))
        #expect(session.mutationActivity?.didSucceed == false)
        #expect(session.undoableArchive == nil, "A failed archive offered an undo")

        let after = try #require(session.state.snapshot)
        #expect(after.loadedMessageCount == before.loadedMessageCount)
        #expect(session.loadedMessages(forSenderKey: before.senders[0].id).count == 3)
    }

    @Test("Every mutation error states that the mailbox was not changed")
    func failuresSayTheMailboxIsUntouched() {
        let errors: [MailMutationError] = [
            .notSupported, .permissionRequired, .permissionDeclined, .authorizationExpired,
            .accountChanged, .messageNotInLoadedWindow, .messageNoLongerAvailable, .rateLimited,
            .network(reason: "Offline."), .rejectedByProvider(reason: "Refused."), .cancelled,
        ]

        for error in errors {
            #expect(!error.changedTheMailbox)
            #expect(
                error.failureReason?.contains("Nothing was changed") == true,
                "\(error) didn't say the mailbox was untouched"
            )
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
    }

    // MARK: - Local reconciliation

    @Test("An archived message leaves the Inbox window and the sender count follows")
    func archivingUpdatesTheWindowAndTheSummary() async throws {
        let messages = (1...4).map { message("m-\($0)", hours: Double($0)) }
        let (session, _, _) = await makeSession(messages: messages)
        let key = messages[0].sender.groupingKey

        #expect(try #require(session.state.snapshot).senders[0].messageCount == 4)

        await session.archiveMessage(MailMessageID("m-2")).value

        let after = try #require(session.state.snapshot)
        #expect(after.loadedMessageCount == 3)
        #expect(after.senders[0].messageCount == 3)
        #expect(!session.loadedMessages(forSenderKey: key).contains { $0.id == MailMessageID("m-2") })
        #expect(!session.reviewedMessages(forSenderKey: key).contains { $0.id == MailMessageID("m-2") })
    }

    @Test("A proposal and a dry-run preview both recompute over the smaller window")
    func proposalsAndPlansRecompute() async throws {
        let messages = ProposalFixtures.promotionalSender(count: 16)
        let (session, _, _) = await makeSession(messages: messages)
        let key = messages[0].sender.groupingKey

        let planBefore = session.cleanupPlan(for: [CleanupPlanRequest(senderKey: key, action: .keepNewest(count: 5))])
        let affectedBefore = planBefore.totalAffectedMessageCount
        #expect(session.proposal(forSenderKey: key) != nil)

        await session.archiveMessage(messages[0].id).value

        let planAfter = session.cleanupPlan(for: [CleanupPlanRequest(senderKey: key, action: .keepNewest(count: 5))])
        #expect(planAfter.window.loadedMessageCount == 15, "The plan window still counted the archived message")
        #expect(planAfter.totalAffectedMessageCount == affectedBefore - 1)

        // The proposal was recomputed rather than carried over: it still exists, and it is
        // derived from the fifteen messages that remain.
        let proposal = try #require(session.proposal(forSenderKey: key))
        #expect(proposal.loadedMessageCount == 15)
    }

    @Test("Archiving a protected message updates the protection counts with it")
    func protectionRecomputes() async throws {
        let messages = [
            message("m-plain", hours: 1),
            message("m-starred", hours: 2, labels: [.inbox, .starred]),
            message("m-plain-2", hours: 3),
        ]
        let (session, _, _) = await makeSession(messages: messages)
        let key = messages[0].sender.groupingKey

        #expect(try #require(session.state.snapshot).senders[0].starredCount == 1)
        #expect(session.reviewedMessages(forSenderKey: key).count { $0.isProtected } == 1)

        await session.archiveMessage(MailMessageID("m-starred")).value

        #expect(try #require(session.state.snapshot).senders[0].starredCount == 0)
        #expect(session.reviewedMessages(forSenderKey: key).count { $0.isProtected } == 0)
    }

    @Test("The cache is rewritten with the state Gmail confirmed, not the state before it")
    func cachePersistsTheConfirmedState() async throws {
        let cache = RecordingInboxCache()
        let messages = (1...3).map { message("m-\($0)", hours: Double($0)) }
        let (session, _, _) = await makeSession(messages: messages, cache: cache)

        await session.archiveMessage(MailMessageID("m-1")).value

        let saved = try #require(await cache.lastSaved)
        #expect(saved.messages.count == 2)
        #expect(!saved.messages.contains { $0.id == MailMessageID("m-1") })
        #expect(saved.senders.reduce(0) { $0 + $1.messageCount } == 2)
        #expect(saved.summariesMatchMessages, "The stored summaries stopped describing the stored messages")
    }

    @Test("A refresh from the provider agrees with what the archive left behind")
    func refreshAgreesWithTheMutation() async throws {
        let messages = (1...4).map { message("m-\($0)", hours: Double($0)) }
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            archiver: StubMessageArchiver()
        )
        let session = InboxSessionModel(
            provider: provider,
            fetchRequest: MailFetchRequest(limit: 4),
            now: { Self.epoch }
        )
        await session.connect().value
        await session.archiveMessage(MailMessageID("m-2")).value
        #expect(try #require(session.state.snapshot).loadedMessageCount == 3)

        // Gmail's inbox list no longer returns the archived message, which is exactly what the
        // local state already says. The two agree without the app having to be told twice.
        let remaining = messages.filter { $0.id != MailMessageID("m-2") }
        await provider.setFetchBehavior(.pages([MailMessagePage(messages: remaining)]))
        await session.reload().value

        let refreshed = try #require(session.state.snapshot)
        #expect(refreshed.loadedMessageCount == 3)
        #expect(!session.loadedMessages(forSenderKey: messages[0].sender.groupingKey)
            .contains { $0.id == MailMessageID("m-2") })
    }

    @Test("A confirmed archive that cannot be written down is still reported as a success")
    func localPersistenceFailureIsNotARemoteFailure() async throws {
        // The distinction that matters most in this interval: Gmail changed the mailbox, and
        // this Mac could not write the record. Reporting that as a failure would tell the user
        // the opposite of what happened to their mail.
        let store = FailingMutationRecordStore()
        let (session, _, archiver) = await makeSession(
            messages: [message("m-1"), message("m-2")],
            records: store
        )

        await session.archiveMessage(MailMessageID("m-1")).value

        let activity = try #require(session.mutationActivity)
        #expect(activity.didSucceed, "A local write failure was reported as a remote failure")
        #expect(activity.localRecordWarning == FailingMutationRecordStore.refusalReason)
        #expect(session.undoableArchive?.messageID == MailMessageID("m-1"), "Undo was withdrawn over a local failure")

        // The remote change really did happen, and the window says so.
        #expect(archiver.archiveRequests.count == 1)
        #expect(try #require(session.state.snapshot).loadedMessageCount == 1)
    }

    // MARK: - Undo

    @Test("A successful archive can be undone, and the message comes back where it was")
    func undoRestoresTheMessageInPlace() async throws {
        let messages = (1...4).map { message("m-\($0)", hours: Double($0)) }
        let (session, _, archiver) = await makeSession(messages: messages)
        let key = messages[0].sender.groupingKey
        let orderBefore = session.loadedMessages(forSenderKey: key).map(\.id)

        await session.archiveMessage(MailMessageID("m-3")).value
        #expect(session.undoableArchive?.messageID == MailMessageID("m-3"))
        #expect(try #require(session.state.snapshot).loadedMessageCount == 3)

        await session.undoLastArchive().value

        let undoRequests = archiver.undoRequests
        #expect(undoRequests.count == 1, "Undo did not reach the provider")
        #expect(undoRequests.first?.messageID == MailMessageID("m-3"))

        let after = try #require(session.state.snapshot)
        #expect(after.loadedMessageCount == 4)
        #expect(after.senders[0].messageCount == 4)
        // Back in the same place, because membership is derived from labels rather than the
        // entry being removed and re-appended.
        #expect(session.loadedMessages(forSenderKey: key).map(\.id) == orderBefore)
        #expect(session.undoableArchive == nil, "The undo offer survived a successful undo")
    }

    @Test("Undo restores the message that was archived, and no other")
    func undoRestoresOnlyTheArchivedMessage() async throws {
        let messages = (1...3).map { message("m-\($0)", hours: Double($0)) }
        let (session, _, archiver) = await makeSession(messages: messages)

        await session.archiveMessage(MailMessageID("m-2")).value
        await session.undoLastArchive().value

        #expect(archiver.undoRequests.map(\.messageID) == [MailMessageID("m-2")])
        #expect(try #require(session.state.snapshot).loadedMessageCount == 3)
    }

    @Test("A failed undo leaves the archive standing, and says so separately")
    func undoFailureIsReportedSeparately() async throws {
        let archiver = StubMessageArchiver(undoBehavior: .fails(.rateLimited))
        let (session, _, _) = await makeSession(
            messages: [message("m-1"), message("m-2")],
            archiver: archiver
        )

        await session.archiveMessage(MailMessageID("m-1")).value
        #expect(try #require(session.state.snapshot).loadedMessageCount == 1)

        await session.undoLastArchive().value

        #expect(session.mutationActivity?.error == .rateLimited)
        // The archive really happened, so the window still reflects it. Putting the message
        // back because the undo failed would be the app rewriting history it does not own.
        #expect(try #require(session.state.snapshot).loadedMessageCount == 1)
        // And the offer stands, because the message is still archived and still restorable.
        #expect(session.undoableArchive?.messageID == MailMessageID("m-1"))
    }

    @Test("Undo twice cannot put the window into an inconsistent state")
    func repeatedUndoIsSafe() async throws {
        let messages = (1...3).map { message("m-\($0)", hours: Double($0)) }
        let (session, _, archiver) = await makeSession(messages: messages)

        await session.archiveMessage(MailMessageID("m-1")).value
        await session.undoLastArchive().value

        // The offer is gone, so the second undo is refused before anything is sent.
        await session.undoLastArchive().value
        await session.undoLastArchive().value

        #expect(archiver.undoRequests.count == 1, "A repeated undo reached the provider again")
        let after = try #require(session.state.snapshot)
        #expect(after.loadedMessageCount == 3)
        #expect(after.senders[0].messageCount == 3)
    }

    @Test("The undo offer survives a reload, because it is backed by the transaction file")
    func undoOfferSurvivesAReload() async throws {
        // The behaviour this interval changes deliberately. Previously the offer lived only in
        // memory and a reload ended it; now it is re-derived from the stored transaction for
        // whichever account is on screen, so reloading to look at the mailbox is no longer a way
        // to lose the ability to take an archive back.
        let messages = (1...3).map { message("m-\($0)", hours: Double($0)) }
        let (session, _, _) = await makeSession(messages: messages)

        await session.archiveMessage(MailMessageID("m-1")).value
        #expect(session.undoableArchive != nil)

        await session.reload().value

        #expect(session.undoableArchive?.messageID == MailMessageID("m-1"), "The undo offer did not survive a reload")
        // The result banner has no backing store and is not re-derived.
        #expect(session.mutationActivity == nil)
    }

    @Test("Dismissing the result keeps the offer, and archiving again supersedes it")
    func undoOfferIsSupersededNotDismissed() async throws {
        let messages = (1...4).map { message("m-\($0)", hours: Double($0)) }
        let records = EphemeralMutationRecordStore()
        let (session, _, _) = await makeSession(messages: messages, records: records)

        await session.archiveMessage(MailMessageID("m-1")).value
        let firstTransactionID = try #require(session.undoableArchive?.id)

        // Closing the sheet is how somebody gets back to their mailbox, not how they say the
        // archive was what they wanted.
        session.dismissMutationActivity()
        #expect(session.mutationActivity == nil)
        #expect(session.undoableArchive?.messageID == MailMessageID("m-1"), "Dismissing the banner withdrew the undo offer")

        await session.archiveMessage(MailMessageID("m-2")).value
        #expect(session.undoableArchive?.messageID == MailMessageID("m-2"), "The offer named the wrong archive")

        // One undoable transaction per account: the first is superseded rather than deleted, so
        // the audit history still says what the app did, and the UI never claims two
        // independent undos.
        let history = await records.transactions(for: .testAccount)
        #expect(history.count == 2)
        #expect(history.count(where: \.isUndoable) == 1)
        #expect(history.first { $0.id == firstTransactionID }?.undoState == .superseded)
    }

    // MARK: - The local record

    @Test("Each confirmed mutation writes one record, naming the operation and the message")
    func recordsAreWritten() async throws {
        let records = EphemeralMutationRecordStore()
        let messages = (1...3).map { message("m-\($0)", hours: Double($0)) }
        let (session, _, _) = await makeSession(messages: messages, records: records)

        await session.archiveMessage(MailMessageID("m-1")).value
        await session.undoLastArchive().value

        let history = await session.mutationHistory()
        #expect(history.count == 2)
        #expect(Set(history.map(\.operation)) == [.archive, .restoreToInbox])
        #expect(history.allSatisfy { $0.isConfirmed })
        #expect(history.allSatisfy { $0.accountAddress == MailAccount.testAccount.emailAddress.address })
        #expect(history.allSatisfy { $0.confirmedMessageCount == 1 })

        // Both records say they confirmed one message. Only one of them still *names* it:
        // `succeededMessageIDs` is the list of messages a transaction could still undo, and a
        // fully undone archive has none left. What it did is carried by the count, which is why
        // the archive above still reads as confirmed rather than as one that failed.
        let archive = try #require(history.first { $0.operation == .archive })
        let undo = try #require(history.first { $0.operation == .restoreToInbox })
        #expect(archive.succeededMessageIDs.isEmpty)
        #expect(archive.undoState == .undone)
        #expect(!archive.isUndoable)
        #expect(undo.succeededMessageIDs == [MailMessageID("m-1")])
    }

    @Test("A refused mutation is recorded as a failure, not left out")
    func failedMutationsAreRecorded() async throws {
        let records = EphemeralMutationRecordStore()
        let archiver = StubMessageArchiver(archiveBehavior: .fails(.rateLimited))
        let (session, _, _) = await makeSession(
            messages: [message("m-1")],
            archiver: archiver,
            records: records
        )

        await session.archiveMessage(MailMessageID("m-1")).value

        let history = await session.mutationHistory()
        #expect(history.count == 1)
        #expect(history[0].outcome == .failed)
        #expect(!history[0].isConfirmed)
    }

    @Test("Disconnecting removes the record of what was archived")
    func disconnectClearsTheRecord() async throws {
        let records = EphemeralMutationRecordStore()
        let (session, _, _) = await makeSession(messages: [message("m-1")], records: records)

        await session.archiveMessage(MailMessageID("m-1")).value
        #expect(await records.transactions(for: .testAccount).count == 1)

        await session.disconnect().value
        #expect(await records.transactions(for: .testAccount).isEmpty)
    }
}

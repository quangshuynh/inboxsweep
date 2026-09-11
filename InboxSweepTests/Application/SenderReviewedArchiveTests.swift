import Foundation
import Testing
@testable import InboxSweep

/// The sender-level convenience, end to end: deriving a starting selection, editing it, freezing
/// it, and finding out that the mailbox moved underneath it.
///
/// ### What this suite is actually guarding
///
/// A sender-level *action* is the shape a safety claim is easiest to lose. "Archive this sender"
/// is one small step from "archive everything matching this rule", and a convenience that started
/// as a filled-in checkbox column can become an execution path one commit at a time.
///
/// So the cases here are mostly about the distance between a sender and a mutation. Deriving
/// candidates writes nothing. Preselecting writes nothing. Changing the selection writes nothing.
/// Freezing writes nothing. What the user confirms is exactly what goes to the boundary — no
/// wider, no narrower, and never the sender itself.
@MainActor
@Suite("Sender-reviewed archiving")
struct SenderReviewedArchiveTests {

    nonisolated static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func message(
        _ id: String,
        from: String = "deals@example.com",
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

    /// - Parameters:
    ///   - scope: The scope the session starts on. `.allMail` is what lets a case watch a message
    ///     that has *left the Inbox* stay in the window, which is the only way to reach the
    ///     inbox-membership half of the pre-flight check.
    ///   - servedPages: How many times the provider will serve `messages`. More than one is
    ///     needed by any case that reloads.
    private func makeSession(
        messages: [MailMessage],
        archiver: StubMessageArchiver = StubMessageArchiver(),
        records: any MailMutationRecording = EphemeralMutationRecordStore(),
        scope: MailboxScope = .inbox,
        servedPages: Int = 1
    ) async -> (InboxSessionModel, StubMessageArchiver) {
        let provider = StubMailProvider(
            fetch: .pages(Array(repeating: MailMessagePage(messages: messages), count: servedPages)),
            archiver: archiver
        )
        let session = InboxSessionModel(
            provider: provider,
            mutationRecords: records,
            fetchRequest: MailFetchRequest(limit: max(messages.count, 1), scope: scope),
            now: { Self.epoch }
        )
        await session.connect().value
        return (session, archiver)
    }

    private var senderKey: SenderSummary.ID { "deals@example.com" }

    // MARK: - Deriving candidates

    @Test("The candidates are exactly what the dry run says the action would affect")
    func candidatesMatchTheDryRun() async throws {
        let messages = (1...10).map { message("m-\($0)", daysAgo: Double($0) * 10) }
        let (session, archiver) = await makeSession(messages: messages)

        let action = PlannedCleanupAction.keepNewest(count: 3)
        let candidates = session.senderReviewCandidates(forSenderKey: senderKey, under: action)

        // The preview's own verdict, asked for separately and required to agree. These are two
        // readings of one computation, and the point of the assertion is that a sender-level
        // entry point cannot open a review that disagrees with the screen it was pressed on.
        let affected = session.reviewedMessages(forSenderKey: senderKey, under: action)
            .filter(\.isAffectedByPlan)
            .map(\.id)

        #expect(candidates.messageIDs == affected)
        #expect(candidates.count == 7, "Keeping the newest 3 of 10 leaves 7")
        #expect(candidates.loadedMessageCount == 10)
        #expect(candidates.action == action)
        #expect(candidates.senderKey == senderKey)
        #expect(candidates.emptyReason == nil)
        #expect(archiver.allRequests.isEmpty, "Deriving candidates reached the mutation boundary")
    }

    @Test("A cutoff action's candidates are the messages past the cutoff, and only those")
    func candidatesHonourACutoff() async throws {
        // Five well inside a 30-day cutoff and five well outside it, so the boundary is not
        // being probed with dates that round either way.
        let recent = (1...5).map { message("recent-\($0)", daysAgo: Double($0)) }
        let old = (1...5).map { message("old-\($0)", daysAgo: 60 + Double($0)) }
        let (session, archiver) = await makeSession(messages: recent + old)

        let candidates = session.senderReviewCandidates(
            forSenderKey: senderKey,
            under: .archiveMessagesOlderThan(days: 30)
        )

        #expect(Set(candidates.messageIDs) == Set(old.map(\.id)))
        #expect(candidates.outOfScopeMessageCount == 5, "The recent five are out of scope, not protected")
        #expect(candidates.protectedMessageCount == 0)
        #expect(archiver.allRequests.isEmpty)
    }

    @Test("Protected messages are never preselected, however the action reaches them")
    func protectedMessagesAreNeverCandidates() async throws {
        let plain = (1...6).map { message("m-\($0)", daysAgo: 100 + Double($0)) }
        let starred = message("starred", daysAgo: 200, labels: [.inbox, .starred])
        let important = message("important", daysAgo: 210, labels: [.inbox, .important])
        let (session, archiver) = await makeSession(messages: plain + [starred, important])

        for action in PlannedCleanupAction.offered {
            let candidates = session.senderReviewCandidates(forSenderKey: senderKey, under: action)
            #expect(
                !candidates.messageIDs.contains(starred.id),
                "A starred message was preselected under \(action.displayName)"
            )
            #expect(
                !candidates.messageIDs.contains(important.id),
                "An Important message was preselected under \(action.displayName)"
            )
        }

        // And the two are counted as held back rather than silently missing, so the screen can
        // say what it did with them.
        let cutoff = session.senderReviewCandidates(
            forSenderKey: senderKey,
            under: .archiveMessagesOlderThan(days: 30)
        )
        #expect(cutoff.count == 6)
        #expect(cutoff.protectedMessageCount == 2)
        #expect(archiver.allRequests.isEmpty)
    }

    @Test("A sender whose mail is all recent produces no candidates, and says why")
    func zeroCandidatesWhenEverythingIsOutOfScope() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: Double($0)) }
        let (session, archiver) = await makeSession(messages: messages)

        let candidates = session.senderReviewCandidates(
            forSenderKey: senderKey,
            under: .archiveMessagesOlderThan(days: 90)
        )

        #expect(candidates.isEmpty)
        #expect(candidates.emptyReason == .everyMessageOutOfScope)
        // Factual about the reason, and offering nothing in place of the empty selection.
        let explanation = try #require(candidates.emptyExplanation)
        #expect(explanation.contains("Nothing is selected"))
        #expect(explanation.contains("5 loaded messages"))
        #expect(archiver.allRequests.isEmpty)
    }

    @Test("A sender whose mail is all protected produces no candidates, and says that instead")
    func zeroCandidatesWhenEverythingIsProtected() async throws {
        let messages = (1...4).map {
            message("m-\($0)", daysAgo: 100 + Double($0), labels: [.inbox, .starred])
        }
        let (session, archiver) = await makeSession(messages: messages)

        let candidates = session.senderReviewCandidates(
            forSenderKey: senderKey,
            under: .archiveMessagesOlderThan(days: 30)
        )

        #expect(candidates.isEmpty)
        #expect(candidates.emptyReason == .everyMessageProtected)
        #expect(candidates.protectedMessageCount == 4)
        #expect(try #require(candidates.emptyExplanation).contains("holds back"))
        #expect(archiver.allRequests.isEmpty)
    }

    @Test("An action that moves nothing produces no candidates rather than everything")
    func zeroCandidatesForAnActionThatMovesNothing() async throws {
        let messages = (1...6).map { message("m-\($0)", daysAgo: 100 + Double($0)) }
        let (session, _) = await makeSession(messages: messages)

        let candidates = session.senderReviewCandidates(forSenderKey: senderKey, under: .reviewSubscription)

        #expect(candidates.isEmpty)
        #expect(candidates.emptyReason == .actionMovesNoMessages)
        #expect(candidates.outOfScopeMessageCount == 6)
    }

    @Test("A sender the window no longer holds produces no candidates and no guess")
    func zeroCandidatesForASenderThatHasLeftTheWindow() async throws {
        let messages = (1...4).map { message("m-\($0)", daysAgo: Double($0) * 20) }
        let (session, _) = await makeSession(messages: messages)

        // The state a proposal generated a while ago can find itself in.
        let candidates = session.senderReviewCandidates(
            forSenderKey: "someone.else@example.net",
            under: .keepNewest(count: 1)
        )

        #expect(candidates.isEmpty)
        #expect(candidates.loadedMessageCount == 0)
        #expect(candidates.emptyReason == .noLoadedMessages)
    }

    @Test("Candidates are recomputed from the window, so a deeper load changes them")
    func candidatesFollowTheLoadedWindow() async throws {
        let firstPage = (1...4).map { message("m-\($0)", daysAgo: Double($0) * 10) }
        let secondPage = (5...8).map { message("m-\($0)", daysAgo: Double($0) * 10) }
        let archiver = StubMessageArchiver()
        let provider = StubMailProvider(
            fetch: .pages([
                MailMessagePage(messages: firstPage, nextPageToken: MailPageToken("p2")),
                MailMessagePage(messages: secondPage),
            ]),
            archiver: archiver
        )
        let session = InboxSessionModel(
            provider: provider,
            fetchRequest: MailFetchRequest(limit: 4),
            now: { Self.epoch }
        )
        await session.connect().value

        let action = PlannedCleanupAction.keepNewest(count: 2)
        let before = session.senderReviewCandidates(forSenderKey: senderKey, under: action)
        #expect(before.count == 2, "Four loaded, newest two kept")

        await session.loadMore().value
        let after = session.senderReviewCandidates(forSenderKey: senderKey, under: action)

        #expect(after.loadedMessageCount == 8)
        #expect(after.count == 6, "Eight loaded, newest two kept")
        #expect(after.messageIDs != before.messageIDs, "Candidates were cached across a load")
        #expect(archiver.allRequests.isEmpty)
    }

    @Test("Candidates never include another sender's mail")
    func candidatesAreSenderBounded() async throws {
        let ours = (1...5).map { message("ours-\($0)", daysAgo: 100 + Double($0)) }
        let theirs = (1...5).map {
            message("theirs-\($0)", from: "news@other.example", daysAgo: 100 + Double($0))
        }
        let (session, _) = await makeSession(messages: ours + theirs)

        for action in PlannedCleanupAction.offered {
            let candidates = session.senderReviewCandidates(forSenderKey: senderKey, under: action)
            #expect(candidates.senderKey == senderKey)
            for id in candidates.messageIDs {
                #expect(id.rawValue.hasPrefix("ours-"), "A candidate belonged to another sender")
            }
        }
    }

    // MARK: - Preselection is a starting point, not a decision

    @Test("The user can drop a preselected message, and the frozen set drops it too")
    func deselectingNarrowsTheFrozenSet() async throws {
        let messages = (1...8).map { message("m-\($0)", daysAgo: 100 + Double($0)) }
        let (session, archiver) = await makeSession(messages: messages)

        let candidates = session.senderReviewCandidates(
            forSenderKey: senderKey,
            under: .archiveMessagesOlderThan(days: 30)
        )
        #expect(candidates.count == 8)

        // What the review screen's checkbox column does when two rows are unticked.
        let kept = candidates.messageIDs.filter { $0 != messages[0].id && $0 != messages[3].id }
        let frozen = try #require(session.makeArchiveSelection(forSenderKey: senderKey, messageIDs: kept))

        #expect(frozen.count == 6)
        #expect(!frozen.messageIDs.contains(messages[0].id))
        #expect(!frozen.messageIDs.contains(messages[3].id))
        #expect(archiver.allRequests.isEmpty, "Editing a preselection reached the mutation boundary")
    }

    @Test("The user can add a protected message the preselection refused, and is warned")
    func manuallyAddingAProtectedMessageIsAllowedAndFlagged() async throws {
        let plain = (1...4).map { message("m-\($0)", daysAgo: 100 + Double($0)) }
        let starred = message("starred", daysAgo: 150, labels: [.inbox, .starred])
        let (session, archiver) = await makeSession(messages: plain + [starred])

        let candidates = session.senderReviewCandidates(
            forSenderKey: senderKey,
            under: .archiveMessagesOlderThan(days: 30)
        )
        #expect(!candidates.messageIDs.contains(starred.id), "The app picked a protected message")

        // The user ticks it themselves. That is allowed — it is their mail — and the frozen set
        // carries the fact so the confirmation can say so.
        let frozen = try #require(session.makeArchiveSelection(
            forSenderKey: senderKey,
            messageIDs: candidates.messageIDs + [starred.id]
        ))

        #expect(frozen.count == 5)
        #expect(frozen.containsProtectedMessages)
        #expect(frozen.protectedMessages.map(\.id) == [starred.id])
        #expect(archiver.allRequests.isEmpty)
    }

    @Test("A preselection cannot be grown into another sender's mail")
    func aPreselectionStaysSenderBounded() async throws {
        let ours = (1...4).map { message("ours-\($0)", daysAgo: 100 + Double($0)) }
        let theirs = message("theirs-1", from: "news@other.example", daysAgo: 120)
        let (session, archiver) = await makeSession(messages: ours + [theirs])

        let candidates = session.senderReviewCandidates(
            forSenderKey: senderKey,
            under: .archiveMessagesOlderThan(days: 30)
        )

        // Refused outright rather than narrowed back to the four that do belong: a confirmation
        // for "the ones that were valid" would be a confirmation of a set nobody assembled.
        #expect(session.makeArchiveSelection(
            forSenderKey: senderKey,
            messageIDs: candidates.messageIDs + [theirs.id]
        ) == nil)
        #expect(archiver.allRequests.isEmpty)
    }

    // MARK: - Freezing and executing

    @Test("Exactly the frozen identifiers reach the mutation boundary, one request each")
    func theFrozenSetIsWhatIsSent() async throws {
        let messages = (1...9).map { message("m-\($0)", daysAgo: 100 + Double($0)) }
        let (session, archiver) = await makeSession(messages: messages)

        let candidates = session.senderReviewCandidates(
            forSenderKey: senderKey,
            under: .keepNewest(count: 3)
        )
        // Edited after preselection, so the set that runs is demonstrably the user's and not
        // the preview's.
        let chosen = Array(candidates.messageIDs.dropFirst())
        let frozen = try #require(session.makeArchiveSelection(forSenderKey: senderKey, messageIDs: chosen))

        await session.archiveSelection(frozen).value

        #expect(archiver.archiveRequests.map(\.messageID) == frozen.messageIDs)
        #expect(archiver.undoRequests.isEmpty)
        #expect(archiver.peakConcurrentRequests == 1, "A set fanned out")

        // Nothing the user unticked, and nothing the preview left out, was touched.
        let sent = Set(archiver.archiveRequests.map(\.messageID))
        let untouched = messages.map(\.id).filter { !sent.contains($0) }
        #expect(untouched.count == 4)
        for id in untouched {
            #expect(!sent.contains(id))
        }
    }

    @Test("The same confirmation cannot be carried out twice")
    func duplicateExecutionIsRefused() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: 100 + Double($0)) }
        let (session, archiver) = await makeSession(messages: messages)

        let candidates = session.senderReviewCandidates(
            forSenderKey: senderKey,
            under: .archiveMessagesOlderThan(days: 30)
        )
        let frozen = try #require(session.makeArchiveSelection(
            forSenderKey: senderKey,
            messageIDs: candidates.messageIDs
        ))

        await session.archiveSelection(frozen).value
        #expect(archiver.archiveRequests.count == 5)

        // The sheet is still on screen showing the same frozen set. Pressing again is refused
        // rather than sent: the work is done, and a repeat would re-ask about every message.
        #expect(!session.canArchive(frozen), "A carried-out confirmation still offered its button")
        #expect(session.validateAgainstLoadedWindow(frozen) == .alreadyExecuted)
        await session.archiveSelection(frozen).value
        #expect(archiver.archiveRequests.count == 5, "A second submission reached the boundary")
    }

    @Test("Switching the loaded scope invalidates a set frozen against the old one")
    func scopeChangeInvalidatesAFrozenSet() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: 100 + Double($0)) }
        let (session, archiver) = await makeSession(messages: messages)

        let frozen = try #require(session.makeArchiveSelection(
            forSenderKey: senderKey,
            messageIDs: messages.prefix(3).map(\.id)
        ))
        #expect(frozen.scope == .inbox, "A frozen set should record the window it was frozen under")
        #expect(session.canArchive(frozen))

        // The same set, frozen while a different part of the mailbox was on screen. Every
        // identifier in it is loaded, this sender's, and in the Inbox — and it is a set somebody
        // assembled from a list of Promotions, which is not the list in front of them now.
        //
        // Built directly rather than by re-scoping the session, so what is under test is the
        // check and not a stub provider's paging.
        let fromAnotherScope = ArchiveSelectionSnapshot(
            accountAddress: frozen.accountAddress,
            senderKey: frozen.senderKey,
            senderDisplayValue: frozen.senderDisplayValue,
            scope: .promotions,
            messages: frozen.messages,
            frozenAt: Self.epoch
        )

        #expect(!session.canArchive(fromAnotherScope))
        #expect(session.validateAgainstLoadedWindow(fromAnotherScope) == .selectionChanged)
        await session.archiveSelection(fromAnotherScope).value
        #expect(archiver.archiveRequests.isEmpty, "A set frozen under another scope was archived")
    }

    @Test("A message that has already left the Inbox invalidates the set rather than being re-sent")
    func aMessageArchivedElsewhereInvalidatesTheSet() async throws {
        // Read under *All mail*, which is the scope where a message that has left the Inbox stays
        // in the window rather than dropping out of it. Under Inbox the same situation is caught a
        // step earlier — the message is simply not there any more — and the membership check would
        // never be reached.
        let messages = (1...5).map { message("m-\($0)", daysAgo: 100 + Double($0)) }
        let (session, archiver) = await makeSession(messages: messages, scope: .allMail)

        let frozen = try #require(session.makeArchiveSelection(
            forSenderKey: senderKey,
            messageIDs: [messages[0].id, messages[1].id, messages[2].id]
        ))
        #expect(session.canArchive(frozen))

        // One of the three leaves the Inbox between the review and the confirmation.
        await session.archiveMessage(messages[1].id).value
        #expect(archiver.archiveRequests.count == 1)
        #expect(
            session.loadedMessages(forSenderKey: senderKey).count == 5,
            "All mail should still describe the archived message"
        )

        #expect(!session.canArchive(frozen), "A set naming an already-archived message stayed confirmable")
        #expect(session.validateAgainstLoadedWindow(frozen) == .selectionChanged)
        await session.archiveSelection(frozen).value
        #expect(archiver.archiveRequests.count == 1, "An already-archived message was archived again")
    }

    // MARK: - Results

    @Test("A sender-reviewed archive that half works is reported, recorded, and undone as half")
    func partialSenderReviewedArchive() async throws {
        let messages = (1...6).map { message("m-\($0)", daysAgo: 100 + Double($0)) }
        let archiver = StubMessageArchiver()
        archiver.setBehavior(.fails(.messageNoLongerAvailable), forMessage: MailMessageID("m-2"))
        archiver.setBehavior(.fails(.rateLimited), forMessage: MailMessageID("m-5"))
        let records = EphemeralMutationRecordStore()
        let (session, _) = await makeSession(messages: messages, archiver: archiver, records: records)

        let candidates = session.senderReviewCandidates(
            forSenderKey: senderKey,
            under: .archiveMessagesOlderThan(days: 30)
        )
        #expect(candidates.count == 6)
        let frozen = try #require(session.makeArchiveSelection(
            forSenderKey: senderKey,
            messageIDs: candidates.messageIDs
        ))

        await session.archiveSelection(frozen).value

        // The result is three numbers, not a verdict.
        let activity = try #require(session.mutationActivity)
        #expect(activity.selectedCount == 6)
        #expect(activity.confirmedCount == 4)
        #expect(activity.failedCount == 2)

        // Activity agrees with it, and says it was one sender's mail without saying the sender
        // was archived.
        let entry = try #require(await session.activityHistory().first)
        #expect(entry.title == "Archived 4 of 6 messages from one sender")
        #expect(entry.selectedCount == 6)
        #expect(entry.confirmedCount == 4)
        #expect(!entry.title.lowercased().contains("all"))
        #expect(!entry.explanation.lowercased().contains("future"))

        // And the undo offer names the four that really were archived.
        let undoable = try #require(session.undoableArchive)
        #expect(undoable.succeededCount == 4)
        #expect(!undoable.succeededMessageIDs.contains(MailMessageID("m-2")))
        #expect(!undoable.succeededMessageIDs.contains(MailMessageID("m-5")))

        await session.undoLastArchive().value
        #expect(Set(archiver.undoRequests.map(\.messageID)) == Set(undoable.succeededMessageIDs))
    }

    @Test("A sender-reviewed archive nothing confirmed is recorded as such, and offers no undo")
    func totallyFailedSenderReviewedArchive() async throws {
        let messages = (1...4).map { message("m-\($0)", daysAgo: 100 + Double($0)) }
        let archiver = StubMessageArchiver(archiveBehavior: .fails(.rateLimited))
        let (session, _) = await makeSession(messages: messages, archiver: archiver)

        let candidates = session.senderReviewCandidates(
            forSenderKey: senderKey,
            under: .archiveMessagesOlderThan(days: 30)
        )
        let frozen = try #require(session.makeArchiveSelection(
            forSenderKey: senderKey,
            messageIDs: candidates.messageIDs
        ))
        await session.archiveSelection(frozen).value

        let entry = try #require(await session.activityHistory().first)
        #expect(entry.title == "No messages were archived")
        #expect(entry.confirmedCount == 0)
        #expect(!entry.isUndoable)
        #expect(session.undoableArchive == nil)

        // Every one of them is still in the Inbox, and still this sender's.
        #expect(session.loadedMessages(forSenderKey: senderKey).count == 4)
    }

    @Test("A session-ending failure stops the run and reports the rest as never sent")
    func sessionEndingFailureStopsTheRun() async throws {
        let messages = (1...6).map { message("m-\($0)", daysAgo: 100 + Double($0)) }
        let archiver = StubMessageArchiver()
        archiver.setBehavior(.fails(.authorizationExpired), forMessage: MailMessageID("m-3"))
        let (session, _) = await makeSession(messages: messages, archiver: archiver)

        let candidates = session.senderReviewCandidates(
            forSenderKey: senderKey,
            under: .archiveMessagesOlderThan(days: 30)
        )
        let frozen = try #require(session.makeArchiveSelection(
            forSenderKey: senderKey,
            messageIDs: candidates.messageIDs
        ))
        await session.archiveSelection(frozen).value

        let activity = try #require(session.mutationActivity)
        #expect(activity.selectedCount == 6)
        #expect(activity.confirmedCount + activity.failedCount + activity.notAttemptedCount == 6)
        #expect(activity.notAttemptedCount > 0, "A withdrawn grant kept sending requests")
        #expect(
            archiver.archiveRequests.count < 6,
            "Every remaining message was sent after the grant was gone"
        )
    }

    @Test("A sender-reviewed archive's undo survives a relaunch and restores only its own messages")
    func undoSurvivesARelaunch() async throws {
        let messages = (1...6).map { message("m-\($0)", daysAgo: 100 + Double($0)) }
        let archiver = StubMessageArchiver()
        let records = EphemeralMutationRecordStore()
        let (session, _) = await makeSession(messages: messages, archiver: archiver, records: records)

        let candidates = session.senderReviewCandidates(
            forSenderKey: senderKey,
            under: .keepNewest(count: 2)
        )
        let frozen = try #require(session.makeArchiveSelection(
            forSenderKey: senderKey,
            messageIDs: candidates.messageIDs
        ))
        await session.archiveSelection(frozen).value
        #expect(frozen.count == 4)

        // A second session over the same transaction file and the same mailbox: the app, quit
        // and reopened.
        let (relaunched, _) = await makeSession(messages: messages, archiver: archiver, records: records)

        let restored = try #require(relaunched.undoableArchive)
        #expect(restored.id == frozen.id)
        #expect(Set(restored.succeededMessageIDs) == Set(frozen.messageIDs))
        #expect(try #require(await relaunched.activityHistory().first).isUndoable)

        await relaunched.undoLastArchive().value
        #expect(Set(archiver.undoRequests.map(\.messageID)) == Set(frozen.messageIDs))
        #expect(relaunched.undoableArchive == nil)
    }
}

import Foundation
import Testing
@testable import InboxSweep

/// Choosing the messages, and freezing the choice.
///
/// Everything in this suite happens before anything is sent. That is the point of keeping it
/// separate from the execution suite: selecting, preselecting, and opening a confirmation are all
/// operations that must reach no provider at all, and a test file that also archived would make
/// that easy to lose sight of. Every case here ends by asserting the archiver was never called.
@MainActor
@Suite("Selecting messages to archive")
struct MessageSelectionTests {

    nonisolated static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func message(
        _ id: String,
        from: String = "newsletter@example.com",
        daysAgo: Double = 0,
        labels: Set<MailLabel> = [.inbox],
        subject: String? = nil
    ) -> MailMessage {
        MailMessage(
            id: MailMessageID(id),
            sender: EmailAddressParser.parse(from),
            subject: subject ?? "Subject \(id)",
            receivedAt: Self.epoch.addingTimeInterval(-daysAgo * 86_400),
            labels: labels
        )
    }

    private func makeSession(
        messages: [MailMessage],
        archiver: StubMessageArchiver = StubMessageArchiver()
    ) async -> (InboxSessionModel, StubMessageArchiver) {
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            archiver: archiver
        )
        let session = InboxSessionModel(
            provider: provider,
            fetchRequest: MailFetchRequest(limit: max(messages.count, 1)),
            now: { Self.epoch }
        )
        await session.connect().value
        return (session, archiver)
    }

    // MARK: - Freezing a set

    @Test("A set of several messages from one sender freezes exactly those messages")
    func freezesTheChosenMessages() async throws {
        let messages = (1...8).map { message("m-\($0)", daysAgo: Double($0)) }
        let (session, archiver) = await makeSession(messages: messages)
        let key = messages[0].sender.groupingKey

        let chosen: [MailMessageID] = [MailMessageID("m-2"), MailMessageID("m-5"), MailMessageID("m-7")]
        let frozen = try #require(session.makeArchiveSelection(forSenderKey: key, messageIDs: chosen))

        #expect(frozen.count == 3)
        #expect(Set(frozen.messageIDs) == Set(chosen))
        #expect(frozen.accountAddress == MailAccount.testAccount.emailAddress.address)
        #expect(frozen.senderKey == key)

        // Ordered by the review list rather than by whatever order the ticks arrived in, so the
        // confirmation reads top-to-bottom like the screen it came from. Newest first.
        #expect(frozen.messageIDs == [MailMessageID("m-2"), MailMessageID("m-5"), MailMessageID("m-7")])

        // Each message is described well enough to recognise, and no further.
        let first = try #require(frozen.messages.first)
        #expect(first.subject == "Subject m-2")
        #expect(first.receivedAt == messages[1].receivedAt)

        #expect(archiver.allRequests.isEmpty, "Freezing a selection contacted the provider")
    }

    @Test("Deselecting narrows the set, and an empty selection freezes nothing")
    func deselectionNarrowsTheSet() async throws {
        let messages = (1...5).map { message("m-\($0)", daysAgo: Double($0)) }
        let (session, archiver) = await makeSession(messages: messages)
        let key = messages[0].sender.groupingKey

        var ticked: Set<MailMessageID> = [MailMessageID("m-1"), MailMessageID("m-2"), MailMessageID("m-3")]
        #expect(session.makeArchiveSelection(forSenderKey: key, messageIDs: ticked)?.count == 3)

        ticked.remove(MailMessageID("m-2"))
        let narrowed = try #require(session.makeArchiveSelection(forSenderKey: key, messageIDs: ticked))
        #expect(Set(narrowed.messageIDs) == [MailMessageID("m-1"), MailMessageID("m-3")])

        // "Archive nothing" is not an operation, so there is no snapshot for it and no
        // confirmation that could be opened on one.
        #expect(session.makeArchiveSelection(forSenderKey: key, messageIDs: [] as [MailMessageID]) == nil)
        #expect(archiver.allRequests.isEmpty)
    }

    @Test("A selection cannot cross a sender boundary")
    func selectionCannotCrossSenders() async throws {
        let mine = (1...4).map { message("mine-\($0)", from: "newsletter@example.com", daysAgo: Double($0)) }
        let theirs = (1...4).map { message("theirs-\($0)", from: "offers@shop.example", daysAgo: Double($0)) }
        let (session, archiver) = await makeSession(messages: mine + theirs)
        let key = mine[0].sender.groupingKey

        // Refused outright rather than quietly narrowed to the members that do belong. A
        // confirmation built from the survivors would be a confirmation of a set the user never
        // ticked on the screen they ticked it on.
        let mixed = [MailMessageID("mine-1"), MailMessageID("theirs-1")]
        #expect(session.makeArchiveSelection(forSenderKey: key, messageIDs: mixed) == nil)

        // The other sender's own key cannot rescue it either: a snapshot names one sender.
        #expect(session.makeArchiveSelection(forSenderKey: theirs[0].sender.groupingKey, messageIDs: mixed) == nil)

        // And the honest subset still works.
        #expect(session.makeArchiveSelection(forSenderKey: key, messageIDs: [MailMessageID("mine-1")])?.count == 1)
        #expect(archiver.allRequests.isEmpty)
    }

    @Test("A selection naming a message that has left the window freezes nothing")
    func staleIdentifiersRefuseToFreeze() async throws {
        let messages = (1...4).map { message("m-\($0)", daysAgo: Double($0)) }
        let (session, archiver) = await makeSession(messages: messages)
        let key = messages[0].sender.groupingKey

        let chosen = [MailMessageID("m-1"), MailMessageID("m-gone")]
        #expect(session.makeArchiveSelection(forSenderKey: key, messageIDs: chosen) == nil)
        #expect(archiver.allRequests.isEmpty)
    }

    // MARK: - Preselection from a preview

    @Test("Fill from preview offers exactly what the preview says it would affect")
    func preselectionMatchesThePreview() async throws {
        let messages = ProposalFixtures.promotionalSender(count: 20)
        let (session, archiver) = await makeSession(messages: messages)
        let key = messages[0].sender.groupingKey
        let action = PlannedCleanupAction.keepNewest(count: 5)

        let preselectable = session.preselectableMessageIDs(forSenderKey: key, under: action)
        let affected = session.reviewedMessages(forSenderKey: key, under: action).filter(\.isAffectedByPlan)

        #expect(!preselectable.isEmpty, "The exercise must actually have something to preselect")
        #expect(Set(preselectable) == Set(affected.map(\.id)), "The offer disagreed with the preview beside it")

        // It is a list of identifiers for a checkbox column and nothing else.
        #expect(archiver.allRequests.isEmpty, "Preselection reached the mutation boundary")
        #expect(session.mutationActivity == nil)
        #expect(session.undoableArchive == nil)
    }

    @Test("Fill from preview never picks a protected message, even one the plan would reach")
    func preselectionSkipsProtectedMessages() async throws {
        // Two of these are starred and one is marked important. All three are old enough for the
        // action's scope to reach them, so the only thing holding them back is protection.
        let messages = [
            message("old-1", daysAgo: 300),
            message("old-2", daysAgo: 280),
            message("old-starred", daysAgo: 260, labels: [.inbox, .starred]),
            message("old-important", daysAgo: 240, labels: [.inbox, .important]),
            message("old-3", daysAgo: 220),
            message("recent", daysAgo: 1),
        ]
        let (session, archiver) = await makeSession(messages: messages)
        let key = messages[0].sender.groupingKey
        let action = PlannedCleanupAction.archiveMessagesOlderThan(days: 30)

        let preselectable = session.preselectableMessageIDs(forSenderKey: key, under: action)

        #expect(Set(preselectable) == [MailMessageID("old-1"), MailMessageID("old-2"), MailMessageID("old-3")])
        #expect(!preselectable.contains(MailMessageID("old-starred")), "A convenience action picked a starred message")
        #expect(!preselectable.contains(MailMessageID("old-important")), "A convenience action picked an important message")
        #expect(!preselectable.contains(MailMessageID("recent")), "A convenience action reached outside the action's scope")
        #expect(archiver.allRequests.isEmpty)
    }

    @Test("The user can still select a protected message by hand, and the set says so")
    func manualProtectedSelectionIsAllowedAndFlagged() async throws {
        // The distinction the product model draws: InboxSweep never *picks* a protected message,
        // and never *prevents* somebody archiving their own mail. What it does instead is say so
        // on the confirmation, where the decision is being made.
        let messages = [
            message("plain", daysAgo: 100),
            message("starred", daysAgo: 90, labels: [.inbox, .starred]),
        ]
        let (session, archiver) = await makeSession(messages: messages)
        let key = messages[0].sender.groupingKey

        let frozen = try #require(session.makeArchiveSelection(
            forSenderKey: key,
            messageIDs: [MailMessageID("plain"), MailMessageID("starred")]
        ))

        #expect(frozen.count == 2, "A protected message was silently dropped from the user's own selection")
        #expect(frozen.containsProtectedMessages)
        #expect(frozen.protectedMessages.map(\.id) == [MailMessageID("starred")])
        #expect(frozen.protectedMessages.first?.protectionReason == .starred)
        #expect(archiver.allRequests.isEmpty)
    }

    // MARK: - Opening a confirmation

    @Test("Opening a confirmation sends nothing and starts nothing")
    func openingAConfirmationIsInert() async throws {
        let messages = (1...12).map { message("m-\($0)", daysAgo: Double($0)) }
        let (session, archiver) = await makeSession(messages: messages)
        let key = messages[0].sender.groupingKey

        let frozen = try #require(session.makeArchiveSelection(
            forSenderKey: key,
            messageIDs: messages.prefix(10).map(\.id)
        ))

        // Everything a sheet asks of the session while it is on screen.
        #expect(session.canArchive(frozen))
        #expect(frozen.count == 10)
        _ = frozen.protectedMessages
        _ = frozen.selection()

        #expect(archiver.allRequests.isEmpty, "Opening a confirmation reached the provider")
        #expect(session.mutationActivity == nil, "Opening a confirmation started an operation")
        #expect(try #require(session.state.snapshot).loadedMessageCount == 12, "The window changed before anything was confirmed")
    }

    @Test("A frozen set stops being confirmable when the window stops agreeing with it")
    func freezingSurvivesButConfirmingDoesNot() async throws {
        let messages = (1...6).map { message("m-\($0)", daysAgo: Double($0)) }
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            archiver: StubMessageArchiver()
        )
        let session = InboxSessionModel(
            provider: provider,
            fetchRequest: MailFetchRequest(limit: 6),
            now: { Self.epoch }
        )
        await session.connect().value
        let key = messages[0].sender.groupingKey

        let frozen = try #require(session.makeArchiveSelection(
            forSenderKey: key,
            messageIDs: [MailMessageID("m-1"), MailMessageID("m-2"), MailMessageID("m-3")]
        ))
        #expect(session.canArchive(frozen))

        // Two of the three are gone from the mailbox — somebody archived them in Gmail itself.
        await provider.setFetchBehavior(.pages([MailMessagePage(
            messages: messages.filter { $0.id != MailMessageID("m-2") && $0.id != MailMessageID("m-3") }
        )]))
        await session.reload().value

        // The frozen set still describes what the user reviewed. It simply can no longer be
        // carried out, and the session says so rather than archiving the one that remains.
        #expect(frozen.count == 3, "The frozen set changed under the confirmation")
        #expect(!session.canArchive(frozen))
    }

    @Test("A frozen set built for one account cannot be confirmed against another")
    func accountChangeInvalidatesAFrozenSet() async throws {
        let messages = (1...4).map { message("m-\($0)", daysAgo: Double($0)) }
        let (session, _) = await makeSession(messages: messages)
        let key = messages[0].sender.groupingKey

        let frozen = try #require(session.makeArchiveSelection(
            forSenderKey: key,
            messageIDs: [MailMessageID("m-1"), MailMessageID("m-2")]
        ))
        #expect(session.canArchive(frozen))

        // A set assembled while one mailbox was on screen must never be executable against
        // another, so a snapshot built for a different address is refused on its own terms.
        let foreign = ArchiveSelectionSnapshot(
            accountAddress: "somebody.else@example.net",
            senderKey: frozen.senderKey,
            senderDisplayValue: frozen.senderDisplayValue,
            scope: frozen.scope,
            messages: frozen.messages,
            frozenAt: Self.epoch
        )
        #expect(!session.canArchive(foreign))
    }
}

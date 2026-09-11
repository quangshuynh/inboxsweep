import Foundation
import Testing
@testable import InboxSweep

/// The session's unsubscribe path: what reaches a boundary, what refuses, and what is recorded.
@Suite("Unsubscribe flow")
@MainActor
struct UnsubscribeFlowTests {

    // MARK: - Fixtures

    static let account = MailAccount(
        emailAddress: EmailAddressParser.parse("someone@example.com"),
        providerDisplayName: "Stub"
    )

    static func metadata(_ header: String, post: String? = nil) -> MessageUnsubscribeMetadata {
        ListUnsubscribeParser.metadata(listUnsubscribe: header, listUnsubscribePost: post)
    }

    static let oneClickMetadata = Self.metadata("<https://lists.example/u/abc>", post: "List-Unsubscribe=One-Click")
    static let webMetadata = Self.metadata("<https://lists.example/preferences>")
    static let mailMetadata = Self.metadata("<mailto:leave@lists.example?subject=unsubscribe>")

    static func messages(
        _ unsubscribe: MessageUnsubscribeMetadata,
        from address: String = "news@lists.example",
        count: Int = 4
    ) -> [MailMessage] {
        (1...count).map { index in
            MailMessage(
                id: MailMessageID("m\(index)"),
                sender: EmailAddressParser.parse(address),
                subject: "Issue \(index)",
                receivedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 86_400),
                labels: [.inbox, .categoryPromotions],
                unsubscribe: unsubscribe
            )
        }
    }

    /// A loaded session over one sender with the given metadata.
    static func loadedSession(
        _ unsubscribe: MessageUnsubscribeMetadata,
        unsubscriber: (any MailUnsubscribing)? = RecordingUnsubscriber(),
        opener: any ExternalURLOpening = RecordingURLOpener(),
        records: any MailMutationRecording = EphemeralMutationRecordStore()
    ) async -> InboxSessionModel {
        let provider = StubMailProvider(
            connect: .succeeds(Self.account),
            fetch: .pages([MailMessagePage(messages: Self.messages(unsubscribe))]),
            unsubscriber: unsubscriber
        )
        let model = InboxSessionModel(provider: provider, mutationRecords: records, urlOpener: opener)
        await model.connect().value
        return model
    }

    static let senderKey = "news@lists.example"

    // MARK: - Reading

    @Test("Reading an opportunity contacts nobody and opens nothing")
    func detectionPerformsNoAction() async {
        let unsubscriber = RecordingUnsubscriber()
        let opener = RecordingURLOpener()
        let model = await Self.loadedSession(Self.oneClickMetadata, unsubscriber: unsubscriber, opener: opener)

        // Read it many times over, as a screen re-rendering would.
        for _ in 1...20 {
            _ = model.unsubscribeOpportunity(forSenderKey: Self.senderKey)
        }

        #expect(unsubscriber.requestCount == 0)
        #expect(opener.openCount == 0)
        #expect(model.unsubscribeActivity == nil)
    }

    @Test("Freezing a review contacts nobody, opens nothing, and records nothing")
    func openingAReviewPerformsNoAction() async {
        let unsubscriber = RecordingUnsubscriber()
        let opener = RecordingURLOpener()
        let records = EphemeralMutationRecordStore()
        let model = await Self.loadedSession(Self.oneClickMetadata, unsubscriber: unsubscriber, opener: opener, records: records)

        let review = model.makeUnsubscribeReview(forSenderKey: Self.senderKey)

        #expect(review?.mechanismKind == .oneClick)
        #expect(review?.destinationHost == "lists.example")
        #expect(unsubscriber.requestCount == 0)
        #expect(opener.openCount == 0)
        #expect(await records.unsubscribeEntries(for: Self.account).isEmpty)
    }

    @Test("A sender with no metadata has no review to freeze")
    func noReviewWithoutAMechanism() async {
        let model = await Self.loadedSession(.absent)

        #expect(model.unsubscribeOpportunity(forSenderKey: Self.senderKey).availability == .noEvidence)
        #expect(model.makeUnsubscribeReview(forSenderKey: Self.senderKey) == nil)
    }

    @Test("Malformed metadata cannot be turned into an action")
    func malformedMetadataCannotExecute() async {
        let unsubscriber = RecordingUnsubscriber()
        let model = await Self.loadedSession(
            Self.metadata("<http://lists.example/u>, <javascript:go()>"),
            unsubscriber: unsubscriber
        )

        #expect(model.unsubscribeOpportunity(forSenderKey: Self.senderKey).availability == .ambiguousMetadata)
        #expect(model.makeUnsubscribeReview(forSenderKey: Self.senderKey) == nil)
        #expect(unsubscriber.requestCount == 0)
    }

    // MARK: - One-click

    @Test("A confirmed one-click sends exactly one request, to the reviewed endpoint")
    func confirmedOneClickSendsOneRequest() async throws {
        let unsubscriber = RecordingUnsubscriber()
        let records = EphemeralMutationRecordStore()
        let model = await Self.loadedSession(Self.oneClickMetadata, unsubscriber: unsubscriber, records: records)

        let review = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        await model.confirmUnsubscribe(review).value

        #expect(unsubscriber.requestCount == 1)
        #expect(unsubscriber.requests[0].endpoint.absoluteString == "https://lists.example/u/abc")
        // The request carries the confirmation's own identifier, so a repeat is recognisable.
        #expect(unsubscriber.requests[0].operationID == review.id)

        #expect(model.unsubscribeActivity?.outcome == .requestAccepted(host: "lists.example", statusCode: 200))

        let entries = await records.unsubscribeEntries(for: Self.account)
        #expect(entries.count == 1)
        #expect(entries[0].mechanism == .oneClick)
        #expect(entries[0].outcome == .requestAccepted)
        #expect(entries[0].destinationHost == "lists.example")
    }

    @Test("A 3xx answer is recorded as sent rather than accepted")
    func redirectAnswerIsSentNotAccepted() async throws {
        let unsubscriber = RecordingUnsubscriber { request in
            OneClickUnsubscribeReceipt(host: request.endpoint.host, statusCode: 302, redirectCount: 0)
        }
        let model = await Self.loadedSession(Self.oneClickMetadata, unsubscriber: unsubscriber)

        let review = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        await model.confirmUnsubscribe(review).value

        #expect(model.unsubscribeActivity?.outcome == .requestSent(host: "lists.example", statusCode: 302))
    }

    @Test("A failed request is reported as a failure and still recorded as what was attempted")
    func failedRequestIsRecorded() async throws {
        let records = EphemeralMutationRecordStore()
        let model = await Self.loadedSession(
            Self.oneClickMetadata,
            unsubscriber: RecordingUnsubscriber.failing(.rejectedByEndpoint(host: "lists.example", statusCode: 410)),
            records: records
        )

        let review = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        await model.confirmUnsubscribe(review).value

        #expect(model.unsubscribeActivity?.failure == .rejectedByEndpoint(host: "lists.example", statusCode: 410))
        let entries = await records.unsubscribeEntries(for: Self.account)
        #expect(entries[0].outcome == .requestFailed)
        #expect(entries[0].statusCode == 410)
        #expect(!entries[0].reachedSomebody)
    }

    // MARK: - Handoffs

    @Test("A browser handoff opens the URL and makes no HTTP request of its own")
    func browserHandoffOpensWithoutFetching() async throws {
        let unsubscriber = RecordingUnsubscriber()
        let opener = RecordingURLOpener()
        let records = EphemeralMutationRecordStore()
        let model = await Self.loadedSession(Self.webMetadata, unsubscriber: unsubscriber, opener: opener, records: records)

        let review = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        #expect(review.mechanismKind == .webPage)
        await model.confirmUnsubscribe(review).value

        #expect(opener.openedURLs.map(\.absoluteString) == ["https://lists.example/preferences"])
        // The point of the case: the one-click boundary — the only thing in the session that can
        // make a request — was never touched.
        #expect(unsubscriber.requestCount == 0)
        #expect(model.unsubscribeActivity?.outcome == .browserOpened(host: "lists.example"))

        let entries = await records.unsubscribeEntries(for: Self.account)
        #expect(entries[0].mechanism == .webPage)
        #expect(entries[0].outcome == .browserOpened)
        #expect(entries[0].statusCode == nil)
    }

    @Test("A mail handoff composes and never sends")
    func mailHandoffOpensWithoutSending() async throws {
        let unsubscriber = RecordingUnsubscriber()
        let opener = RecordingURLOpener()
        let model = await Self.loadedSession(Self.mailMetadata, unsubscriber: unsubscriber, opener: opener)

        let review = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        #expect(review.mechanismKind == .mail)
        await model.confirmUnsubscribe(review).value

        let opened = try #require(opener.openedURLs.first)
        #expect(opened.scheme == "mailto")
        #expect(opened.absoluteString.contains("leave@lists.example"))
        #expect(opened.absoluteString.contains("subject=unsubscribe"))

        #expect(unsubscriber.requestCount == 0)
        #expect(model.unsubscribeActivity?.outcome == .mailClientOpened(domain: "lists.example"))
    }

    @Test("A handoff the system declines is a failure, not a silent success")
    func declinedHandoffIsAFailure() async throws {
        let model = await Self.loadedSession(Self.webMetadata, opener: RecordingURLOpener(succeeds: false))

        let review = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        await model.confirmUnsubscribe(review).value

        #expect(model.unsubscribeActivity?.outcome == .handoffFailed(.couldNotOpen))
    }

    @Test("Only https and mailto are ever handed to the system")
    func handoffAllowList() async {
        #expect(UnsubscribeHandoff.permits(URL(string: "https://lists.example/u")!))
        #expect(UnsubscribeHandoff.permits(URL(string: "mailto:a@lists.example")!))

        for refused in ["http://lists.example/u", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "ftp://a.example"] {
            #expect(!UnsubscribeHandoff.permits(URL(string: refused)!), "Should refuse \(refused)")
        }

        // And the guard is applied, not merely available.
        let opener = RecordingURLOpener()
        let failure = await UnsubscribeHandoff.open(URL(string: "javascript:alert(1)")!, with: opener)
        #expect(failure == .refusedDestination)
        #expect(opener.openCount == 0)
    }

    // MARK: - Stale review

    @Test("A rotated endpoint refuses the confirmation rather than aiming it somewhere else")
    func rotatedEndpointRefuses() async throws {
        let unsubscriber = RecordingUnsubscriber()
        let provider = StubMailProvider(
            connect: .succeeds(Self.account),
            fetch: .pages([
                MailMessagePage(messages: Self.messages(Self.oneClickMetadata)),
                MailMessagePage(messages: Self.messages(
                    Self.metadata("<https://somewhere-else.example/u>", post: "List-Unsubscribe=One-Click")
                )),
            ]),
            unsubscriber: unsubscriber
        )
        let model = InboxSessionModel(provider: provider, urlOpener: RecordingURLOpener())
        await model.connect().value

        let review = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        #expect(review.destinationHost == "lists.example")

        // The mailbox moves under the open review.
        await model.reload().value
        #expect(model.unsubscribeOpportunity(forSenderKey: Self.senderKey).mechanism?.destinationHost == "somewhere-else.example")

        await model.confirmUnsubscribe(review).value

        // Refused, and — the part that matters — nothing was sent to either host.
        #expect(model.validateAgainstLoadedWindow(review) == .reviewIsStale)
        #expect(model.unsubscribeActivity?.failure == .reviewIsStale)
        #expect(unsubscriber.requestCount == 0)
    }

    @Test("A review whose source message has left the window is refused")
    func vanishedSourceMessageRefuses() async throws {
        let unsubscriber = RecordingUnsubscriber()
        let provider = StubMailProvider(
            connect: .succeeds(Self.account),
            fetch: .pages([
                MailMessagePage(messages: Self.messages(Self.oneClickMetadata)),
                MailMessagePage(messages: []),
            ]),
            unsubscriber: unsubscriber
        )
        let model = InboxSessionModel(provider: provider, urlOpener: RecordingURLOpener())
        await model.connect().value

        let review = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        await model.reload().value
        await model.confirmUnsubscribe(review).value

        #expect(model.unsubscribeActivity?.failure == .reviewIsStale)
        #expect(unsubscriber.requestCount == 0)
    }

    @Test("A review frozen under another account is refused before anything goes out")
    func accountChangeRefuses() async throws {
        let unsubscriber = RecordingUnsubscriber()
        let model = await Self.loadedSession(Self.oneClickMetadata, unsubscriber: unsubscriber)

        let review = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        let otherAccountReview = UnsubscribeReviewSnapshot(
            accountAddress: "somebody.else@example.com",
            senderKey: review.senderKey,
            senderDisplayValue: review.senderDisplayValue,
            sourceMessageID: review.sourceMessageID,
            scope: review.scope,
            opportunity: review.opportunity,
            mechanism: review.mechanism,
            frozenAt: review.frozenAt
        )

        await model.confirmUnsubscribe(otherAccountReview).value

        #expect(model.unsubscribeActivity?.failure == .accountChanged)
        #expect(unsubscriber.requestCount == 0)
    }

    @Test("A switched scope refuses, because the window the review was read from is gone")
    func scopeChangeRefuses() async throws {
        let unsubscriber = RecordingUnsubscriber()
        let model = await Self.loadedSession(Self.oneClickMetadata, unsubscriber: unsubscriber)

        let review = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        model.scope = .promotions
        await Task.yield()

        #expect(model.validateAgainstLoadedWindow(review) == .reviewIsStale)
        await model.confirmUnsubscribe(review).value
        #expect(unsubscriber.requestCount == 0)
    }

    // MARK: - Duplicate execution

    @Test("One confirmation is one request, however many times it is submitted")
    func duplicateConfirmationIsRefused() async throws {
        let unsubscriber = RecordingUnsubscriber()
        let model = await Self.loadedSession(Self.oneClickMetadata, unsubscriber: unsubscriber)

        let review = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        await model.confirmUnsubscribe(review).value
        #expect(unsubscriber.requestCount == 1)

        // The sheet is still on screen, showing its result. Pressing again does nothing.
        for _ in 1...5 {
            await model.confirmUnsubscribe(review).value
        }
        #expect(unsubscriber.requestCount == 1)

        // Even after the result is dismissed: closing a sheet is not permission to re-send.
        model.dismissUnsubscribeActivity()
        await model.confirmUnsubscribe(review).value
        #expect(unsubscriber.requestCount == 1)
        #expect(model.validateAgainstLoadedWindow(review) == .alreadyPerformed)
    }

    @Test("A deliberate second unsubscribe is a new confirmation with a new identifier")
    func repeatingIsANewExplicitAction() async throws {
        let unsubscriber = RecordingUnsubscriber()
        let model = await Self.loadedSession(Self.oneClickMetadata, unsubscriber: unsubscriber)

        let first = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        await model.confirmUnsubscribe(first).value
        model.dismissUnsubscribeActivity()

        // The user opens the review again and confirms again. That is a new decision, and it is
        // allowed — what is not allowed is the app deciding to repeat on its own.
        let second = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        #expect(second.id != first.id)
        await model.confirmUnsubscribe(second).value

        #expect(unsubscriber.requestCount == 2)
        #expect(unsubscriber.requests.map(\.operationID) == [first.id, second.id])
    }

    @Test("Switching mechanism re-freezes, so a spent confirmation cannot be reused")
    func switchingMechanismRefreezes() async throws {
        let model = await Self.loadedSession(
            Self.metadata("<https://lists.example/u/abc>, <mailto:leave@lists.example>", post: "List-Unsubscribe=One-Click")
        )

        let oneClick = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        #expect(oneClick.mechanismKind == .oneClick)
        #expect(oneClick.alternatives.map(\.kind) == [.webPage, .mail])

        let asMail = try #require(
            model.makeUnsubscribeReview(forSenderKey: Self.senderKey, using: .mail(MailtoUnsubscribeAddress(string: "mailto:leave@lists.example")!))
        )
        #expect(asMail.mechanismKind == .mail)
        #expect(asMail.id != oneClick.id)
    }

    @Test("A mechanism this sender never offered cannot be reviewed")
    func foreignMechanismIsRefused() async {
        let model = await Self.loadedSession(Self.oneClickMetadata)

        let elsewhere = UnsubscribeMechanism.oneClick(HTTPSUnsubscribeURL(string: "https://attacker.example/u")!)
        #expect(model.makeUnsubscribeReview(forSenderKey: Self.senderKey, using: elsewhere) == nil)
    }

    // MARK: - Capability

    @Test("Without a boundary, one-click refuses and detection still works")
    func withoutABoundaryOneClickRefuses() async throws {
        let model = await Self.loadedSession(Self.oneClickMetadata, unsubscriber: nil)

        // Detection is unaffected: it is domain work over mail already loaded.
        #expect(model.unsubscribeOpportunity(forSenderKey: Self.senderKey).mechanism?.kind == .oneClick)
        #expect(!model.canPerformOneClickUnsubscribe)

        let review = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        #expect(model.validateAgainstLoadedWindow(review) == .notSupported)

        await model.confirmUnsubscribe(review).value
        #expect(model.unsubscribeActivity?.failure == .notSupported)
    }

    @Test("A handoff works without a one-click boundary, because it needs a different thing")
    func handoffDoesNotNeedTheOneClickBoundary() async throws {
        let opener = RecordingURLOpener()
        let model = await Self.loadedSession(Self.webMetadata, unsubscriber: nil, opener: opener)

        let review = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        #expect(model.validateAgainstLoadedWindow(review) == nil)

        await model.confirmUnsubscribe(review).value
        #expect(opener.openCount == 1)
        #expect(model.unsubscribeActivity?.outcome == .browserOpened(host: "lists.example"))
    }

    // MARK: - Activity

    @Test("An unsubscribe appears in Activity, distinct from an archive, with no undo")
    func activityRowAppears() async throws {
        let records = EphemeralMutationRecordStore()
        let model = await Self.loadedSession(Self.oneClickMetadata, records: records)

        let review = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        await model.confirmUnsubscribe(review).value

        let timeline = await model.activityTimeline()
        #expect(timeline.count == 1)

        let entry = try #require(timeline[0].unsubscribeEntry)
        #expect(timeline[0].archiveEntry == nil)
        #expect(entry.title == "Unsubscribe request sent")
        #expect(entry.destinationHost == "lists.example")
        #expect(!entry.record.isUndoable)

        // The sender is resolved from the window rather than stored in the record.
        #expect(entry.resolvedSender?.address == "news@lists.example")
        let recorded = await records.unsubscribeEntries(for: Self.account)
        let properties = Set(Mirror(reflecting: recorded[0]).children.compactMap(\.label))
        #expect(properties.isDisjoint(with: ["senderAddress", "senderDisplayName", "subject", "url", "listID"]))
    }

    @Test("Reading Activity sends nothing and opens nothing")
    func activityIsARead() async throws {
        let unsubscriber = RecordingUnsubscriber()
        let opener = RecordingURLOpener()
        let records = EphemeralMutationRecordStore()
        let model = await Self.loadedSession(Self.oneClickMetadata, unsubscriber: unsubscriber, opener: opener, records: records)

        let review = try #require(model.makeUnsubscribeReview(forSenderKey: Self.senderKey))
        await model.confirmUnsubscribe(review).value
        let afterConfirming = unsubscriber.requestCount

        for _ in 1...10 {
            _ = await model.activityTimeline()
            _ = await model.unsubscribeHistory()
        }

        #expect(unsubscriber.requestCount == afterConfirming)
        #expect(opener.openCount == 0)
    }

    @Test("An archive and an unsubscribe interleave by time without merging")
    func timelineInterleaves() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let archive = ActivityEntry(
            transaction: MailMutationTransaction(
                id: UUID(),
                operation: .archive,
                accountAddress: Self.account.emailAddress.address,
                succeededMessageIDs: [MailMessageID("m1")],
                selectedMessageCount: 1,
                occurredAt: now,
                undoState: .undoable
            )
        )
        let unsubscribe = UnsubscribeActivityEntry(
            record: UnsubscribeActionRecord(
                id: UUID(),
                accountAddress: Self.account.emailAddress.address,
                mechanism: .oneClick,
                outcome: .requestAccepted,
                destinationHost: "lists.example",
                occurredAt: now.addingTimeInterval(60)
            )
        )

        let merged = ActivityTimelineEntry.merged(archives: [archive], unsubscribes: [unsubscribe])

        #expect(merged.count == 2)
        #expect(merged[0].unsubscribeEntry != nil)
        #expect(merged[1].archiveEntry != nil)
    }
}

import Foundation
import Testing
@testable import InboxSweep

/// Remembering which senders a user picked, and what they chose to preview for each.
///
/// The riskiest thing about persisting a plan is that a saved plan *looks* like an intention to
/// act. It is not one, and cannot become one — so alongside the round trip and the staleness
/// rules, these cases pin down that restoring a plan does nothing but re-open a preview.
@MainActor
@Suite("Saved cleanup plans")
struct SavedCleanupPlanTests {

    // MARK: - Fixtures

    nonisolated private static let epoch = ProposalFixtures.epoch

    private func mailbox() -> [MailMessage] {
        ProposalFixtures.promotionalSender(count: 12)
            + ProposalFixtures.newsletterSender(count: 10)
            + ProposalFixtures.notificationSender(count: 8)
    }

    private func model(
        messages: [MailMessage]? = nil,
        planStore: RecordingCleanupPlanStore = RecordingCleanupPlanStore(),
        pages: [MailMessagePage]? = nil,
        restorable: MailConnection = .disconnected
    ) -> InboxSessionModel {
        let loaded = messages ?? mailbox()
        return InboxSessionModel(
            provider: StubMailProvider(
                fetch: .pages(pages ?? [MailMessagePage(messages: loaded)]),
                restorable: restorable
            ),
            planStore: planStore,
            fetchRequest: MailFetchRequest(limit: loaded.count),
            now: { Self.epoch }
        )
    }

    private var promotionalKey: SenderSummary.ID {
        EmailAddressParser.parse("deals@example.com").groupingKey
    }

    private var newsletterKey: SenderSummary.ID {
        EmailAddressParser.parse("list@example.org").groupingKey
    }

    // MARK: - Round trip

    @Test("Saved choices come back after a relaunch")
    func roundTripsThroughTheStore() async throws {
        let store = RecordingCleanupPlanStore()
        let first = model(planStore: store)
        await first.connect().value

        // Awaited rather than yielded to: the write is a task the session hands back, and a
        // test that raced it would be flaky rather than wrong.
        await first.savePlan([
            SavedCleanupSelection(senderKey: promotionalKey, action: .keepNewest(count: 3)),
            SavedCleanupSelection(senderKey: newsletterKey, action: .reviewSubscription),
        ]).value
        #expect(store.saveCallCount == 1)

        // A second session over the same store is what a relaunch looks like.
        let relaunched = model(planStore: store, restorable: .connected(.testAccount))
        await relaunched.restore().value

        let restored = try #require(relaunched.savedPlan)
        #expect(restored.usableSelections.count == 2)
        #expect(restored.saved.action(forSenderKey: promotionalKey) == .keepNewest(count: 3))
        #expect(restored.saved.action(forSenderKey: newsletterKey) == .reviewSubscription)
        #expect(!restored.isStale)
    }

    @Test("A plan survives the real file format, including its cutoffs")
    func roundTripsThroughTheFileStore() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inboxsweep-plan-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileCleanupPlanStore(directory: directory)
        let plan = SavedCleanupPlan(
            accountAddress: MailAccount.testAccount.emailAddress.address,
            scope: .promotions,
            selections: [
                SavedCleanupSelection(senderKey: promotionalKey, action: .archiveMessagesOlderThan(days: 90)),
                SavedCleanupSelection(senderKey: newsletterKey, action: .keepNewest(count: 7)),
            ],
            loadedMessageCount: 250,
            savedAt: Self.epoch
        )

        await store.save(plan)

        // Every field, because a format that silently drops the cutoff would restore a plan
        // that says something different from what the user chose.
        #expect(await store.load(for: .testAccount) == plan)
    }

    @Test("Saving an empty selection forgets the plan rather than storing nothing")
    func savingNothingForgets() async throws {
        let store = RecordingCleanupPlanStore()
        let model = model(planStore: store)
        await model.connect().value

        await model.savePlan([SavedCleanupSelection(senderKey: promotionalKey, action: .keepNewest(count: 3))]).value
        await model.savePlan([]).value

        #expect(model.savedPlan == nil)
        #expect(store.clearCallCount >= 1)
    }

    @Test("Disconnecting forgets the saved choices along with the cached mail")
    func disconnectingForgetsThePlan() async throws {
        let store = RecordingCleanupPlanStore()
        let model = model(planStore: store)
        await model.connect().value
        await model.savePlan([SavedCleanupSelection(senderKey: promotionalKey, action: .keepNewest(count: 3))]).value

        await model.disconnect().value

        #expect(model.savedPlan == nil)
        #expect(store.clearCallCount >= 1)
    }

    // MARK: - Account isolation

    @Test("One account's saved choices are never offered to another")
    func plansDoNotCrossAccounts() async throws {
        let other = MailAccount(
            emailAddress: EmailAddressParser.parse("someone.else@example.net"),
            providerDisplayName: "Stub"
        )
        let store = RecordingCleanupPlanStore(seeded: SavedCleanupPlan(
            accountAddress: other.emailAddress.address,
            scope: .inbox,
            selections: [SavedCleanupSelection(senderKey: promotionalKey, action: .keepNewest(count: 5))],
            loadedMessageCount: 30,
            savedAt: Self.epoch
        ))

        let model = model(planStore: store)
        await model.connect().value

        #expect(model.savedPlan == nil, "Another account's sender selections were offered")
    }

    @Test("The file store refuses a plan whose account does not match")
    func fileStoreChecksTheAccount() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inboxsweep-plan-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileCleanupPlanStore(directory: directory)

        await store.save(SavedCleanupPlan(
            accountAddress: "first@example.com",
            scope: .inbox,
            selections: [SavedCleanupSelection(senderKey: promotionalKey, action: .keepNewest(count: 5))],
            loadedMessageCount: 30,
            savedAt: Self.epoch
        ))

        let otherAccount = MailAccount(
            emailAddress: EmailAddressParser.parse("second@example.com"),
            providerDisplayName: "Gmail"
        )
        #expect(await store.load(for: otherAccount) == nil)
    }

    @Test("Saving a second account's plan does not leave the first one's on disk")
    func fileStoreKeepsOneAccount() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inboxsweep-plan-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileCleanupPlanStore(directory: directory)

        let first = MailAccount(emailAddress: EmailAddressParser.parse("first@example.com"), providerDisplayName: "Gmail")
        await store.save(SavedCleanupPlan(
            accountAddress: "first@example.com",
            scope: .inbox,
            selections: [SavedCleanupSelection(senderKey: promotionalKey, action: .keepNewest(count: 5))],
            loadedMessageCount: 30,
            savedAt: Self.epoch
        ))
        await store.save(SavedCleanupPlan(
            accountAddress: "second@example.com",
            scope: .inbox,
            selections: [SavedCleanupSelection(senderKey: newsletterKey, action: .reviewSubscription)],
            loadedMessageCount: 30,
            savedAt: Self.epoch
        ))

        #expect(await store.load(for: first) == nil, "The first account's selections outlived the second's sign-in")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path())
        #expect(files.filter { $0.hasSuffix(".json") }.count == 1)
    }

    // MARK: - Staleness

    @Test("A plan saved under different rules is marked out of date, not silently resumed")
    func rulesVersionChangeInvalidates() async throws {
        let store = RecordingCleanupPlanStore(seeded: SavedCleanupPlan(
            accountAddress: MailAccount.testAccount.emailAddress.address,
            scope: .inbox,
            selections: [SavedCleanupSelection(senderKey: promotionalKey, action: .keepNewest(count: 3))],
            rulesVersion: CleanupProposalRules.version - 1,
            loadedMessageCount: 30,
            savedAt: Self.epoch
        ))
        let model = model(planStore: store)
        await model.connect().value

        let restored = try #require(model.savedPlan)
        #expect(restored.isStale)
        #expect(restored.isInvalidated, "A plan made under different reasoning resumed as if nothing changed")
        #expect(restored.staleness.contains { reason in
            if case .rulesVersionChanged = reason { return true }
            return false
        })
    }

    @Test("A deep load makes a plan stale, and says by how much")
    func deeperLoadingMakesAPlanStale() async throws {
        let first = MailMessagePage(
            messages: ProposalFixtures.promotionalSender(count: 12),
            nextPageToken: MailPageToken("page-2")
        )
        let second = MailMessagePage(
            messages: ProposalFixtures.messages(
                from: "Storefront Deals <deals@example.com>",
                subjects: ProposalFixtures.neutralSubjects(30, prefix: "Older sale"),
                hoursApart: 24,
                labels: [.inbox, .categoryPromotions],
                idPrefix: "older"
            ),
            nextPageToken: nil
        )
        let model = InboxSessionModel(
            provider: StubMailProvider(fetch: .pages([first, second])),
            planStore: RecordingCleanupPlanStore(),
            fetchRequest: MailFetchRequest(limit: 12),
            loadDepth: MailboxLoadDepth(messageLimit: 100, pageSize: 12),
            now: { Self.epoch }
        )

        await model.connect().value
        await model.savePlan([SavedCleanupSelection(senderKey: promotionalKey, action: .keepNewest(count: 3))]).value
        #expect(try #require(model.savedPlan).isStale == false)

        await model.loadToDepth().value

        let restored = try #require(model.savedPlan)
        #expect(restored.isStale, "A plan chosen over 12 messages was resumed silently over 42")
        #expect(restored.staleness.contains { reason in
            if case .windowChanged(let saved, let current) = reason { return saved == 12 && current == 42 }
            return false
        })
        // Stale is not the same as invalid: the choices are still the user's, and still usable.
        #expect(!restored.isInvalidated)
    }

    @Test("A page or two of new mail is not treated as a change worth interrupting for")
    func smallWindowChangesAreNotStale() {
        let plan = SavedCleanupPlan(
            accountAddress: MailAccount.testAccount.emailAddress.address,
            scope: .inbox,
            selections: [SavedCleanupSelection(senderKey: promotionalKey, action: .keepNewest(count: 3))],
            loadedMessageCount: 250,
            savedAt: Self.epoch
        )
        let snapshot = InboxSnapshot(
            account: .testAccount,
            loadedMessageCount: 270,
            senders: [],
            sortOrder: .messageVolume,
            scope: .inbox,
            hasMoreMessages: true,
            isLoadingMore: false
        )

        #expect(!plan.restored(into: snapshot).staleness.contains { reason in
            if case .windowChanged = reason { return true }
            return false
        })
    }

    @Test("Senders that are no longer loaded are dropped, and counted")
    func missingSendersAreDroppedAndReported() async throws {
        let store = RecordingCleanupPlanStore(seeded: SavedCleanupPlan(
            accountAddress: MailAccount.testAccount.emailAddress.address,
            scope: .inbox,
            selections: [
                SavedCleanupSelection(senderKey: promotionalKey, action: .keepNewest(count: 3)),
                SavedCleanupSelection(senderKey: "vanished@example.invalid", action: .reviewSubscription),
            ],
            loadedMessageCount: 30,
            savedAt: Self.epoch
        ))
        let model = model(planStore: store)
        await model.connect().value

        let restored = try #require(model.savedPlan)
        #expect(restored.usableSelections.map(\.senderKey) == [promotionalKey])
        #expect(restored.staleness.contains(.sendersNoLongerLoaded(count: 1)))
    }

    @Test("A plan saved while reading one scope says so when another is on screen")
    func scopeChangeIsReported() {
        let plan = SavedCleanupPlan(
            accountAddress: MailAccount.testAccount.emailAddress.address,
            scope: .promotions,
            selections: [SavedCleanupSelection(senderKey: promotionalKey, action: .keepNewest(count: 3))],
            loadedMessageCount: 100,
            savedAt: Self.epoch
        )
        let snapshot = InboxSnapshot(
            account: .testAccount,
            loadedMessageCount: 100,
            senders: [],
            sortOrder: .messageVolume,
            scope: .inbox,
            hasMoreMessages: false,
            isLoadingMore: false
        )

        #expect(plan.restored(into: snapshot).staleness.contains(.scopeChanged(saved: .promotions, current: .inbox)))
    }

    // MARK: - The file format

    @Test("Every offered action survives being written and read back")
    func everyActionRoundTripsThroughItsIdentifier() throws {
        for action in PlannedCleanupAction.offered {
            #expect(PlannedCleanupAction(id: action.id) == action, "\(action.displayName) did not round-trip")
        }
        // Including cutoffs that are not on the menu, since a saved plan outlives the menu.
        #expect(PlannedCleanupAction(id: "keep-newest-17") == .keepNewest(count: 17))
        #expect(PlannedCleanupAction(id: "trash-365") == .trashMessagesOlderThan(days: 365))
    }

    @Test("An action this build does not recognise drops that selection, not the whole plan")
    func unknownActionsAreDropped() throws {
        #expect(PlannedCleanupAction(id: "snooze-forever") == nil)
        #expect(PlannedCleanupAction(id: "keep-newest-") == nil)
        #expect(PlannedCleanupAction(id: "keep-newest-0") == nil)
        #expect(PlannedCleanupAction(id: "archive--5") == nil)

        let record = CleanupPlanDTO.Record(
            version: CleanupPlanDTO.schemaVersion,
            accountAddress: "sample.user@example.com",
            scope: MailboxScope.inbox.rawValue,
            rulesVersion: CleanupProposalRules.version,
            loadedMessageCount: 30,
            savedAt: Self.epoch,
            selections: [
                CleanupPlanDTO.Selection(senderKey: promotionalKey, actionID: "keep-newest-4"),
                CleanupPlanDTO.Selection(senderKey: newsletterKey, actionID: "a-future-action"),
            ]
        )

        let plan = try #require(CleanupPlanDTO.plan(from: record))
        #expect(plan.selections.count == 1)
        #expect(plan.action(forSenderKey: promotionalKey) == .keepNewest(count: 4))
    }

    @Test("A file from another schema version is discarded rather than guessed at")
    func foreignSchemaIsDiscarded() {
        let record = CleanupPlanDTO.Record(
            version: CleanupPlanDTO.schemaVersion + 1,
            accountAddress: "sample.user@example.com",
            scope: MailboxScope.inbox.rawValue,
            rulesVersion: CleanupProposalRules.version,
            loadedMessageCount: 30,
            savedAt: Self.epoch,
            selections: []
        )

        #expect(CleanupPlanDTO.plan(from: record) == nil)
    }

    @Test("A saved plan holds choices, and nothing derived from the mailbox")
    func savedPlansStoreNoMailAndNoVerdicts() {
        let plan = SavedCleanupPlan(
            accountAddress: "sample.user@example.com",
            scope: .inbox,
            selections: [SavedCleanupSelection(senderKey: promotionalKey, action: .keepNewest(count: 3))],
            loadedMessageCount: 30,
            savedAt: Self.epoch
        )

        // No proposal, no reason, no protection verdict, no message. All of that is recomputed
        // from the loaded window every launch, which is what stops a saved plan from carrying
        // a stale verdict back onto the screen.
        let propertyNames = Set(Mirror(reflecting: plan).children.compactMap(\.label))
        #expect(propertyNames.isDisjoint(with: [
            "proposals", "proposal", "reasons", "protection", "strength", "messages",
            "messageIDs", "subjects", "affectedMessageCount",
        ]))

        let selectionProperties = Set(Mirror(reflecting: plan.selections[0]).children.compactMap(\.label))
        #expect(selectionProperties == ["senderKey", "action"])
    }
}

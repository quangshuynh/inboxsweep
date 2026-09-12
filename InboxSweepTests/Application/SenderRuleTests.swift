import Foundation
import Testing
@testable import InboxSweep

/// Sender rules, end to end: what it takes to make one, what it refuses to touch, and the things
/// it cannot be talked into doing.
///
/// ### What this suite is actually guarding
///
/// A rule is the only authorization in this app that outlives the screen that granted it, so it
/// is the feature where a safety claim is easiest to lose quietly. "Archive this sender's future
/// mail" is one small step from "archive anything that looks like this", and a suggestion is one
/// commit away from being a setting.
///
/// So most of the cases here are about **distance**: between a proposal and a rule, between a
/// review and a stored authorization, between a rule and a message it must not touch, and between
/// this feature and every verb it does not have.
@MainActor
@Suite("Sender rules")
struct SenderRuleTests {

    nonisolated static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// Well before every fixture message, so a rule in a test is a rule the mail is newer than.
    ///
    /// Rules only ever act on mail that arrived after them, so a rule created *now* in a suite
    /// whose messages are dated in the past would correctly match nothing, and every execution
    /// case would pass for the wrong reason.
    nonisolated static let longAgo = Date(timeIntervalSince1970: 1_600_000_000)

    private func message(
        _ id: String,
        from: String = "deals@example.com",
        subject: String? = nil,
        daysAgo: Double = 0,
        labels: Set<MailLabel> = [.inbox]
    ) -> MailMessage {
        MailMessage(
            id: MailMessageID(id),
            sender: EmailAddressParser.parse(from),
            subject: subject ?? "Subject \(id)",
            receivedAt: Self.epoch.addingTimeInterval(-daysAgo * 86_400),
            labels: labels
        )
    }

    private func rule(
        senderKey: String = "deals@example.com",
        account: String = MailAccount.testAccount.emailAddress.address,
        enabled: Bool = true,
        createdAt: Date? = nil
    ) -> SenderRule {
        SenderRule(
            accountAddress: account,
            senderKey: senderKey,
            senderDisplayValue: senderKey,
            action: .archiveNewInboxMail,
            isEnabled: enabled,
            createdAt: createdAt ?? Self.longAgo
        )
    }

    private func makeSession(
        messages: [MailMessage],
        rules: [SenderRule] = [],
        archiver: StubMessageArchiver? = StubMessageArchiver(),
        records: any MailMutationRecording = EphemeralMutationRecordStore(),
        ruleStore: (any SenderRuleStoring)? = nil,
        scope: MailboxScope = .inbox,
        servedPages: Int = 1
    ) async -> (InboxSessionModel, StubMessageArchiver?, any SenderRuleStoring) {
        let store = ruleStore ?? EphemeralSenderRuleStore(rules: rules)
        let provider = StubMailProvider(
            fetch: .pages(Array(repeating: MailMessagePage(messages: messages), count: servedPages)),
            archiver: archiver
        )
        let session = InboxSessionModel(
            provider: provider,
            mutationRecords: records,
            ruleStore: store,
            fetchRequest: MailFetchRequest(limit: max(messages.count, 1), scope: scope),
            now: { Self.epoch }
        )
        await session.connect().value
        return (session, archiver, store)
    }

    private var senderKey: SenderSummary.ID { "deals@example.com" }

    // MARK: - Nothing creates a rule except a confirmation

    @Test("A proposal is a suggestion and creates nothing")
    func proposalsCreateNoRule() async {
        // The sender the proposal engine is most likely to flag: high-volume promotional mail.
        let (session, _, store) = await makeSession(messages: ProposalFixtures.promotionalSender())

        // The dashboard computed a verdict about this sender. That is the whole of what
        // detection does.
        #expect(session.state.snapshot?.proposals.isEmpty == false)
        #expect(session.senderRules.isEmpty)
        #expect(await store.rules(for: .testAccount).isEmpty)
    }

    @Test("Opening a review creates nothing")
    func openingAReviewCreatesNoRule() async {
        let (session, _, store) = await makeSession(messages: [message("m-1"), message("m-2")])

        let review = session.makeSenderRuleReview(forSenderKey: senderKey)
        #expect(review != nil)
        #expect(review?.senderKey == senderKey)

        // The review exists as a value. Nothing else does.
        #expect(session.senderRules.isEmpty)
        #expect(await store.rules(for: .testAccount).isEmpty)
    }

    @Test("Abandoning a review creates nothing")
    func cancellingCreatesNoRule() async {
        let (session, _, store) = await makeSession(messages: [message("m-1")])

        // Derived, read, and dropped, which is what closing the sheet does.
        var review = session.makeSenderRuleReview(forSenderKey: senderKey)
        #expect(review != nil)
        review = nil
        _ = review

        #expect(session.senderRules.isEmpty)
        #expect(await store.rules(for: .testAccount).isEmpty)
    }

    @Test("Confirming creates exactly the rule that was frozen, and nothing else")
    func confirmingCreatesTheFrozenRule() async throws {
        let (session, _, store) = await makeSession(messages: [message("m-1"), message("m-2")])
        let review = try #require(session.makeSenderRuleReview(forSenderKey: senderKey))

        await session.createRule(from: review).value

        let stored = await store.rules(for: .testAccount)
        #expect(stored.count == 1)
        // Identity and all. Not a rule *like* the one reviewed: the same value, so nothing can
        // have been retargeted between the screen that described it and the file that holds it.
        #expect(stored.first == review.rule)
        #expect(session.senderRules == stored)
        #expect(session.ruleWriteWarning == nil)
    }

    @Test("A second rule for the same sender is refused rather than stacked")
    func oneRulePerSender() async throws {
        let existing = rule()
        let (session, _, store) = await makeSession(messages: [message("m-1")], rules: [existing])

        // There is nothing to review, because the answer to "I want a rule for this sender" when
        // there is one is to show it.
        #expect(session.makeSenderRuleReview(forSenderKey: senderKey) == nil)
        #expect(session.rule(forSenderKey: senderKey) == existing)
        #expect(await store.rules(for: .testAccount).count == 1)
    }

    @Test("A sender with no parseable address cannot have a rule")
    func unknownSendersCannotBeRuled() async {
        // Everything InboxSweep cannot read a sender for shares one grouping key, so a rule on it
        // would be a rule on "anything malformed" rather than on a correspondent.
        let (session, _, _) = await makeSession(messages: [
            message("m-1", from: "not an address at all")
        ])

        #expect(session.makeSenderRuleReview(forSenderKey: EmailAddress.unknownGroupingKey) == nil)

        // And the matcher refuses it from the other end, so neither half relies on the other.
        let outcome = SenderRuleMatching.outcome(
            of: rule(senderKey: EmailAddress.unknownGroupingKey),
            for: .testAccount,
            in: [message("m-1", from: "not an address at all", daysAgo: -1)],
            alreadyAttempted: []
        )
        #expect(outcome.isEmpty)
    }

    // MARK: - Account scope

    @Test("A rule belongs to one account and is invisible to another")
    func rulesAreAccountScoped() async throws {
        let store = EphemeralSenderRuleStore(rules: [
            rule(account: "someone.else@example.com", createdAt: Self.longAgo)
        ])
        let (session, archiver, _) = await makeSession(
            messages: [message("m-1", daysAgo: -1)],
            ruleStore: store
        )

        // Connected as `sample.user@example.com`, so the other account's rule is not listed…
        #expect(session.senderRules.isEmpty)
        #expect(session.rule(forSenderKey: senderKey) == nil)
        // …and it did not run, even though the loaded window is full of mail it would match.
        #expect(archiver?.archiveRequests.isEmpty == true)
    }

    @Test("A rule never executes against a mailbox it was not created for")
    func rulesDoNotActAcrossAccounts() {
        let other = MailAccount(
            emailAddress: EmailAddressParser.parse("someone.else@example.com"),
            providerDisplayName: "Stub",
            providerMessageCount: 1
        )
        let outcome = SenderRuleMatching.outcome(
            of: rule(),
            for: other,
            in: [message("m-1", daysAgo: -1)],
            alreadyAttempted: []
        )
        #expect(outcome.isEmpty)
    }

    @Test("Deleting a rule for one account leaves another account's alone")
    func deletionIsAccountScoped() async {
        let mine = rule()
        let theirs = rule(senderKey: "news@example.org", account: "someone.else@example.com")
        let store = EphemeralSenderRuleStore(rules: [mine, theirs])

        _ = await store.delete(ruleID: theirs.id, for: .testAccount)

        // Asked for by identifier, refused because it is not this account's.
        let other = MailAccount(
            emailAddress: EmailAddressParser.parse("someone.else@example.com"),
            providerDisplayName: "Stub",
            providerMessageCount: 1
        )
        #expect(await store.rules(for: other).count == 1)
        #expect(await store.rules(for: .testAccount) == [mine])
    }

    // MARK: - Exact identity

    @Test("Matching is equality on the address, and nothing that resembles it")
    func matchingIsExact() {
        let near = [
            "deals@example.com.evil.example",   // a suffix, not this sender
            "sub.deals@example.com",            // a different local part
            "deals@mail.example.com",           // a subdomain is a different host
            "deals+offers@example.com",         // sub-addressing is preserved, so this differs
            "notdeals@example.com",
        ]

        for address in near {
            let outcome = SenderRuleMatching.outcome(
                of: rule(),
                for: .testAccount,
                in: [message("m-1", from: address, daysAgo: -1)],
                alreadyAttempted: []
            )
            #expect(outcome.isEmpty, "A rule matched a near miss: \(address)")
        }

        // And the sender it names does match, so the case above is not passing on a typo.
        let hit = SenderRuleMatching.outcome(
            of: rule(),
            for: .testAccount,
            in: [message("m-1", from: "deals@example.com", daysAgo: -1)],
            alreadyAttempted: []
        )
        #expect(hit.matched == [MailMessageID("m-1")])
    }

    @Test("A sender changing display name changes nothing, because names are not matched")
    func displayNamesAreNotMatched() {
        let renamed = message("m-1", from: "Totally Different Name <deals@example.com>", daysAgo: -1)
        let outcome = SenderRuleMatching.outcome(
            of: rule(),
            for: .testAccount,
            in: [renamed],
            alreadyAttempted: []
        )
        #expect(outcome.matched == [MailMessageID("m-1")])
    }

    // MARK: - What a rule refuses to touch

    @Test("A disabled rule executes nothing")
    func disabledRulesDoNotExecute() async {
        let (session, archiver, _) = await makeSession(
            messages: [message("m-1", daysAgo: -1), message("m-2", daysAgo: -2)],
            rules: [rule(enabled: false)]
        )

        #expect(session.senderRules.count == 1)
        #expect(archiver?.archiveRequests.isEmpty == true)
        #expect(session.ruleRun == nil)
    }

    @Test("A deleted rule executes nothing on the next load")
    func deletedRulesDoNotExecute() async throws {
        let existing = rule()
        let (session, archiver, _) = await makeSession(
            messages: [message("m-1", daysAgo: -1)],
            rules: [existing],
            servedPages: 2
        )
        // It ran once, on the load that connected.
        #expect(archiver?.archiveRequests.count == 1)

        await session.deleteRule(existing).value
        #expect(session.senderRules.isEmpty)

        await session.reload().value
        // Still one. The reload loaded the same message again and nothing acted on it.
        #expect(archiver?.archiveRequests.count == 1)
    }

    @Test("A protected message is left in the Inbox and reported, never archived")
    func protectedMessagesAreNotArchived() async throws {
        let messages = [
            message("m-plain", daysAgo: -1),
            message("m-receipt", subject: "Your order receipt", daysAgo: -2),
            message("m-starred", daysAgo: -3, labels: [.inbox, .starred]),
        ]
        let (session, archiver, _) = await makeSession(messages: messages, rules: [rule()])

        // Exactly one request, for exactly the unprotected message.
        #expect(archiver?.archiveRequests.map(\.messageID) == [MailMessageID("m-plain")])

        // And the user is told what was left behind, rather than it happening silently.
        let run = try #require(session.ruleRun)
        #expect(run.protectedCount == 2)
        #expect(run.protectedSummary != nil)
        #expect(run.archivedCount == 1)
    }

    @Test("A message that is not in the Inbox is not mutated")
    func nonInboxMessagesAreNotMutated() async {
        let (session, archiver, _) = await makeSession(
            messages: [message("m-archived", daysAgo: -1, labels: [.categoryPromotions])],
            rules: [rule()],
            scope: .allMail
        )

        #expect(archiver?.archiveRequests.isEmpty == true)
        #expect(session.ruleRun == nil)
    }

    @Test("Mail that arrived before the rule is never retroactively archived")
    func existingMailIsNotTouched() async {
        // Every fixture message here predates the rule, which is the ordinary case the moment
        // somebody creates a rule for a sender whose mail they have just been reading.
        let (session, archiver, _) = await makeSession(
            messages: [message("m-1", daysAgo: 1), message("m-2", daysAgo: 2)],
            rules: [rule(createdAt: Self.epoch.addingTimeInterval(-3_600))]
        )

        #expect(archiver?.archiveRequests.isEmpty == true)
        #expect(session.ruleRun == nil)
    }

    @Test("One loaded message is attempted at most once a session")
    func messagesAreNotRetried() async throws {
        let archiver = StubMessageArchiver(archiveBehavior: .fails(.rateLimited))
        let (session, _, _) = await makeSession(
            messages: [message("m-1", daysAgo: -1)],
            rules: [rule()],
            archiver: archiver,
            servedPages: 3
        )

        #expect(archiver.archiveRequests.count == 1)

        // Two more loads of the same failing message produce no further requests. A retry loop
        // against somebody's quota is the one thing an automatic feature must not have.
        await session.reload().value
        await session.reload().value
        #expect(archiver.archiveRequests.count == 1)
    }

    @Test("A rule never archives more than one pass's worth at a time")
    func passesAreBounded() {
        let many = (0..<(SenderRuleMatching.maximumMessagesPerPass + 10)).map {
            message("m-\($0)", daysAgo: Double(-$0 - 1))
        }
        let outcome = SenderRuleMatching.outcome(
            of: rule(),
            for: .testAccount,
            in: many,
            alreadyAttempted: []
        )

        #expect(outcome.matched.count == SenderRuleMatching.maximumMessagesPerPass)
        #expect(outcome.deferredCount == 10)
        // Oldest first, so what the limit leaves behind is the newest mail, which is the mail the
        // user is most likely to want to see anyway.
        #expect(outcome.matched.first == MailMessageID("m-0"))
    }

    // MARK: - What a rule does when it runs

    @Test("A rule archives through the message-level boundary, one message at a time")
    func executionUsesTheProvenBoundary() async throws {
        let archiver = StubMessageArchiver()
        let (_, _, _) = await makeSession(
            messages: [message("m-1", daysAgo: -1), message("m-2", daysAgo: -2)],
            rules: [rule()],
            archiver: archiver
        )

        #expect(archiver.archiveRequests.count == 2)
        // The same request a person pressing Archive makes: one message, named individually, with
        // the account the window belongs to. No sender, no query, no batch.
        for request in archiver.archiveRequests {
            #expect(request.accountAddress == MailAccount.testAccount.emailAddress.address)
        }
        #expect(archiver.peakConcurrentRequests == 1)
        // Nothing was put back, and nothing else was called.
        #expect(archiver.undoRequests.isEmpty)
    }

    @Test("What a rule archived is recorded, attributed to the rule, and not undoable")
    func executionIsRecordedWithoutAnUndo() async throws {
        let records = EphemeralMutationRecordStore()
        let ruleValue = rule()
        let (session, _, _) = await makeSession(
            messages: [message("m-1", daysAgo: -1)],
            rules: [ruleValue],
            records: records
        )

        let history = await session.activityHistory()
        let entry = try #require(history.first)
        #expect(entry.confirmedCount == 1)
        #expect(entry.origin == .rule(ruleValue.id))
        #expect(entry.wasAutomatic)
        #expect(entry.title.contains("by rule"))
        #expect(entry.ruleAttribution != nil)

        // The deliberate absence. A rule-driven archive is never the account's undo offer, so
        // nothing here is undoable and the existing offer is untouched.
        #expect(!entry.isUndoable)
        #expect(!entry.transaction.isUndoable)
        #expect(session.undoableArchive == nil)
    }

    @Test("A rule pass never takes over an undo the user earned")
    func rulesDoNotSupersedeAUserUndo() async throws {
        let archiver = StubMessageArchiver()
        let (session, _, _) = await makeSession(
            messages: [message("m-1", daysAgo: 1), message("m-new", daysAgo: -1)],
            // Created between the two, so `m-1` is the user's to archive and `m-new` is the
            // rule's. A rule that had matched both would have archived `m-1` before the user
            // could, and this case would be measuring the wrong thing.
            rules: [rule(createdAt: Self.epoch.addingTimeInterval(-12 * 3_600))],
            archiver: archiver,
            servedPages: 2
        )

        // The user archives an older message themselves, and gets an undo for it.
        let selection = try #require(
            session.makeArchiveSelection(forSenderKey: senderKey, messageIDs: [MailMessageID("m-1")])
        )
        await session.archiveSelection(selection).value
        let earned = try #require(session.undoableArchive)
        #expect(earned.succeededMessageIDs == [MailMessageID("m-1")])

        // A reload runs the rule again over a window that still holds `m-new`… except that it was
        // already attempted, so the interesting assertion is simply that the offer survived.
        await session.reload().value
        #expect(session.undoableArchive?.id == earned.id)
    }

    @Test("Failures stop a pass and never disable a rule")
    func failuresLeaveRulesAlone() async throws {
        let archiver = StubMessageArchiver(archiveBehavior: .fails(.authorizationExpired))
        let (session, _, store) = await makeSession(
            messages: [message("m-1", daysAgo: -1)],
            rules: [rule()],
            archiver: archiver
        )

        let run = try #require(session.ruleRun)
        #expect(run.haltedBy == .authorizationExpired)
        #expect(run.failureSummary != nil)

        // The authorization is the user's. The app reports what happened and withdraws nothing.
        let stored = await store.rules(for: .testAccount)
        #expect(stored.count == 1)
        #expect(stored.first?.isEnabled == true)
    }

    @Test("A session that cannot archive runs nothing, and says so rather than failing")
    func aReadOnlySessionRunsNothing() async {
        let archiver = StubMessageArchiver(capability: .requiresAdditionalPermission)
        let (session, _, _) = await makeSession(
            messages: [message("m-1", daysAgo: -1)],
            rules: [rule()],
            archiver: archiver
        )

        #expect(archiver.archiveRequests.isEmpty)
        #expect(session.ruleRun == nil)
        #expect(!session.canExecuteRules)
        // The rule is still there. A read-only grant is not a reason to forget a decision.
        #expect(session.senderRules.count == 1)
    }

    @Test("A provider with no mutation boundary cannot run a rule at all")
    func noBoundaryMeansNoExecution() async {
        let (session, _, _) = await makeSession(
            messages: [message("m-1", daysAgo: -1)],
            rules: [rule()],
            archiver: nil
        )

        #expect(!session.canExecuteRules)
        #expect(session.ruleRun == nil)
        #expect(session.senderRules.count == 1)
    }

    // MARK: - Disconnecting

    @Test("Disconnecting deletes the rules with the rest of the account's local state")
    func disconnectForgetsRules() async {
        let (session, _, store) = await makeSession(
            messages: [message("m-1", daysAgo: 1)],
            rules: [rule()]
        )
        #expect(session.senderRules.count == 1)

        await session.disconnect().value

        #expect(session.senderRules.isEmpty)
        #expect(await store.rules(for: .testAccount).isEmpty)
    }
}

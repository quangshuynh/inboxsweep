import Foundation
import Testing
@testable import InboxSweep

/// Guards the promise this interval makes: InboxSweep reads, and cannot write.
///
/// These are not tests of a feature — they are tests of an *absence*. They exist so that a
/// later change which quietly adds a mutating scope, a non-GET Gmail call, or a message body
/// to the domain model fails here rather than in someone's mailbox.
///
/// Interval 3 adds cleanup *proposals* and a dry-run planner, which is exactly the point at
/// which the boundary is most likely to slip: the app now names the actions it would take.
/// The cases under "Cleanup previews" assert that naming them is all it does.
@Suite("Read-only safety boundary")
struct SafetyBoundaryTests {

    // MARK: - Permissions

    @Test("Exactly one Gmail scope is requested, and it is the metadata scope")
    func requestsOnlyMetadataScope() {
        #expect(GmailScope.requested == ["https://www.googleapis.com/auth/gmail.metadata"])
    }

    @Test("No scope that could change, send, or delete mail is ever requested")
    func requestsNoMutatingScope() {
        for scope in GmailScope.prohibitedForReadOnlyOperation {
            #expect(!GmailScope.requested.contains(scope), "Requested a mutating scope: \(scope)")
            #expect(!GmailScope.requestedScopeParameter.contains(scope))
        }
    }

    @Test("The requested scope does not grant access to message bodies")
    func requestsNoBodyAccess() {
        // `gmail.readonly` would work for this interval's features but would also hand the
        // app every message body. The narrower scope is the point.
        #expect(!GmailScope.requested.contains("https://www.googleapis.com/auth/gmail.readonly"))
    }

    // MARK: - Request surface

    @Test("Every Gmail API request the app can build is a GET")
    func buildsOnlyReadRequests() {
        for request in GmailAPIEndpoint.allRequestBuilders() {
            #expect(request.method == "GET", "Non-GET Gmail request: \(request.url)")
        }
    }

    @Test("No Gmail write endpoint is reachable from any request the app can build")
    func buildsNoWriteEndpoint() {
        // Gmail's mutating operations all live at named paths. A future change that adds one
        // has to add a builder for it, and a builder for it shows up here.
        let writePathFragments = [
            "modify", "batchModify", "trash", "untrash", "delete", "batchDelete",
            "send", "import", "insert", "labels", "settings", "watch", "stop",
        ]

        for request in GmailAPIEndpoint.allRequestBuilders() {
            let path = request.url.path().lowercased()
            for fragment in writePathFragments {
                #expect(
                    !path.contains(fragment.lowercased()),
                    "Gmail request reaches a mutating path: \(request.url)"
                )
            }
        }
    }

    @Test("Message requests ask for metadata, never for full or raw content")
    func requestsMetadataFormatOnly() {
        let url = GmailAPIEndpoint.messageMetadata(id: MailMessageID("m-1")).url.absoluteString

        #expect(url.contains("format=metadata"))
        #expect(!url.contains("format=full"))
        #expect(!url.contains("format=raw"))
        #expect(!url.contains("format=minimal"))
    }

    @Test("Only the headers the app declares are ever requested")
    func requestsDeclaredHeadersOnly() {
        let url = GmailAPIEndpoint.messageMetadata(id: MailMessageID("m-1")).url.absoluteString
        let requested = URLComponents(string: url)?.queryItems?
            .filter { $0.name == "metadataHeaders" }
            .compactMap(\.value) ?? []

        #expect(requested == GmailAPIEndpoint.metadataHeaders)
        #expect(requested == ["From", "Subject", "Date", "List-Unsubscribe"])
    }

    // MARK: - Live traffic

    @Test("A full connect, load, and disconnect sends no write to the Gmail API")
    func endToEndTrafficIsReadOnly() async throws {
        let transport = RecordingHTTPTransport(
            handler: GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 8)).handler()
        )
        let provider = GmailProvider(
            configuration: GmailOAuthConfiguration(clientID: "1234567890-abcdef.apps.googleusercontent.com"),
            transport: transport,
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: InMemoryCredentialStore(),
            retryPolicy: .immediate
        )

        _ = try await provider.connect()
        _ = try await provider.fetchMessages(MailFetchRequest(limit: 8))
        await provider.disconnect()

        let gmailRequests = transport.requests.filter {
            ($0.url?.host ?? "").contains("gmail.googleapis.com")
        }
        #expect(!gmailRequests.isEmpty, "The exercise must actually have called Gmail")

        for request in gmailRequests {
            #expect(request.httpMethod == "GET", "Wrote to Gmail: \(request.httpMethod ?? "?") \(request.url?.path ?? "")")
            #expect(request.httpBody == nil, "A Gmail request carried a body")
        }
    }

    @Test("The only non-GET calls are to Google's own token and revocation endpoints")
    func nonReadCallsAreAuthorizationOnly() async throws {
        let transport = RecordingHTTPTransport(handler: GmailMailboxStub().handler())
        let provider = GmailProvider(
            configuration: GmailOAuthConfiguration(clientID: "1234567890-abcdef.apps.googleusercontent.com"),
            transport: transport,
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: InMemoryCredentialStore(),
            retryPolicy: .immediate
        )

        _ = try await provider.connect()
        _ = try await provider.fetchMessages(MailFetchRequest(limit: 4))
        await provider.disconnect()

        let writes = transport.requests.filter { $0.httpMethod != "GET" }
        let allowed = ["https://oauth2.googleapis.com/token", "https://oauth2.googleapis.com/revoke"]

        for write in writes {
            let url = write.url?.absoluteString ?? ""
            #expect(allowed.contains(url), "Unexpected write to \(url)")
        }
        // Signing out gives the access back rather than only forgetting it locally.
        #expect(writes.contains { $0.url?.absoluteString.hasSuffix("/revoke") == true })
    }

    // MARK: - Domain surface

    @Test("The domain message model has nowhere to put a message body")
    func domainModelStoresNoContent() {
        let message = MailMessage(
            id: MailMessageID("m-1"),
            sender: EmailAddressParser.parse("newsletter@example.com"),
            subject: "A subject",
            receivedAt: .now
        )

        let propertyNames = Set(Mirror(reflecting: message).children.compactMap(\.label))
        let contentBearingNames: Set<String> = ["body", "bodyText", "html", "snippet", "payload", "attachments", "raw"]

        #expect(propertyNames.isDisjoint(with: contentBearingNames))
        #expect(propertyNames == ["id", "threadID", "sender", "subject", "receivedAt", "labels", "hasListUnsubscribeHeader"])
    }

    @Test("A sender summary makes no judgement about the sender")
    func summaryMakesNoJudgement() {
        let summary = SenderSummary(
            sender: EmailAddressParser.parse("newsletter@example.com"),
            messageCount: 40,
            unreadCount: 40,
            starredCount: 0,
            importantCount: 0,
            newestReceivedAt: .now,
            oldestLoadedReceivedAt: .now,
            recentSubjects: []
        )

        // The summary reports. Recommending, scoring, and classifying all live on
        // `SenderCleanupProposal`, and this asserts they never leak back down into the facts.
        let propertyNames = Set(Mirror(reflecting: summary).children.compactMap(\.label))
        let judgementNames: Set<String> = ["score", "isUseless", "isNewsletter", "category", "recommendation", "cleanupScore"]

        #expect(propertyNames.isDisjoint(with: judgementNames))
    }

    @Test("The List-Unsubscribe header is recorded but never acted on")
    func recordsUnsubscribeWithoutActingOnIt() async throws {
        // The proposal rules do read `hasListUnsubscribeHeader` — it is part of what makes a
        // sender read as a mailing list. Reading it is the whole of what the app does with it:
        // there is no unsubscribe feature, and the address the header names is never contacted.
        let messages = [
            GmailFixtures.SyntheticMessage(id: "u1", listUnsubscribe: "<https://example.com/unsub>"),
            GmailFixtures.SyntheticMessage(id: "u2", from: "person@example.net"),
        ]
        let transport = RecordingHTTPTransport(handler: GmailMailboxStub(messages: messages).handler())
        let provider = GmailProvider(
            configuration: GmailOAuthConfiguration(clientID: "1234567890-abcdef.apps.googleusercontent.com"),
            transport: transport,
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: InMemoryCredentialStore(),
            retryPolicy: .immediate
        )
        _ = try await provider.connect()
        let page = try await provider.fetchMessages(MailFetchRequest(limit: 2))

        #expect(page.messages.contains { $0.hasListUnsubscribeHeader })
        // No request was made to the unsubscribe URL itself.
        #expect(!transport.requests.contains { ($0.url?.absoluteString ?? "").contains("unsub") })
    }

    // MARK: - Cleanup previews

    @Test("Building a cleanup preview makes no request of any kind")
    @MainActor
    func dryRunPerformsNoProviderCall() async throws {
        let messages = ProposalFixtures.promotionalSender(count: 20) + ProposalFixtures.newsletterSender(count: 12)
        let provider = StubMailProvider(fetch: .pages([MailMessagePage(messages: messages)]))
        let model = InboxSessionModel(provider: provider)

        await model.connect().value
        let fetchesAfterLoading = await provider.fetchCallCount

        let snapshot = try #require(model.state.snapshot)
        let plan = model.cleanupPlan(
            for: snapshot.senders.map {
                CleanupPlanRequest(senderKey: $0.id, action: .trashMessagesOlderThan(days: 1))
            }
        )

        #expect(!plan.isEmpty, "The exercise must actually have produced a preview")
        #expect(plan.totalAffectedMessageCount > 0, "…and one that would reach something")
        #expect(await provider.fetchCallCount == fetchesAfterLoading, "The preview fetched")
        #expect(await provider.connectCallCount == 1, "The preview re-authorized")
        #expect(await provider.disconnectCallCount == 0)
    }

    @Test("A cleanup preview reaches Gmail not at all, even over a live transport")
    @MainActor
    func dryRunSendsNothingToGmail() async throws {
        let transport = RecordingHTTPTransport(
            handler: GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 12)).handler()
        )
        let provider = GmailProvider(
            configuration: GmailOAuthConfiguration(clientID: "1234567890-abcdef.apps.googleusercontent.com"),
            transport: transport,
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: InMemoryCredentialStore(),
            retryPolicy: .immediate
        )
        let model = InboxSessionModel(provider: provider, fetchRequest: MailFetchRequest(limit: 12))

        await model.connect().value
        let requestsBeforePreview = transport.requests.count

        let snapshot = try #require(model.state.snapshot)
        for action in PlannedCleanupAction.offered {
            _ = model.cleanupPlan(
                for: snapshot.senders.map { CleanupPlanRequest(senderKey: $0.id, action: action) }
            )
        }

        #expect(transport.requests.count == requestsBeforePreview, "Previewing sent a request")
    }

    @Test("A plan carries no way to carry itself out")
    func planIsInertData() {
        let messages = ProposalFixtures.promotionalSender(count: 20)
        let key = messages[0].sender.groupingKey
        let plan = CleanupPlanner.plan(
            requests: [CleanupPlanRequest(senderKey: key, action: .trashMessagesOlderThan(days: 1))],
            messagesBySender: [key: messages],
            proposals: [key: ProposalFixtures.proposal(for: messages)],
            window: CleanupPlanWindow(loadedMessageCount: 20, hasMoreBeyondWindow: false),
            referenceDate: ProposalFixtures.epoch
        )

        // A plan holds counts and sentences. It carries no message identifiers to act on and
        // nothing that could stand in for a provider, so there is nothing here to execute even
        // if a later interval forgot to add the permission first.
        let propertyNames = Set(Mirror(reflecting: plan).children.compactMap(\.label))
        #expect(propertyNames == ["entries", "window", "rulesVersion"])

        for entry in plan.entries {
            let entryProperties = Set(Mirror(reflecting: entry).children.compactMap(\.label))
            let actionableNames: Set<String> = ["messageIDs", "messages", "provider", "threadIDs", "labelIDs"]
            #expect(entryProperties.isDisjoint(with: actionableNames))
        }
    }

    @Test("The planned actions are described, never performed")
    func plannedActionsAreDescriptionsOnly() {
        // Every offered action names something the app cannot do. The wording is part of the
        // boundary: a preview that said "will be" would be a promise nothing can keep.
        for action in PlannedCleanupAction.offered {
            #expect(action.previewVerbPhrase.hasPrefix("would be"))
        }
        #expect(CleanupPlan.disclaimer.contains("no permission"))
    }

    @Test("Proposals are recomputed rather than persisted, so a rules change cannot be outlived")
    func proposalsAreNeverWrittenToDisk() {
        // The cache record is the only thing the app writes. It has no field for a proposal,
        // a reason, or a protection signal, so a stale verdict cannot survive a rules change.
        let record = InboxCacheDTO.Record(
            version: InboxCacheDTO.schemaVersion,
            accountAddress: "someone@example.com",
            accountDisplayName: nil,
            providerDisplayName: "Gmail",
            providerMessageCount: nil,
            nextPageToken: nil,
            savedAt: .now,
            messages: [],
            senders: []
        )

        let propertyNames = Set(Mirror(reflecting: record).children.compactMap(\.label))
        let derivedNames: Set<String> = ["proposals", "proposal", "reasons", "protection", "strength", "rulesVersion"]
        #expect(propertyNames.isDisjoint(with: derivedNames))

        let senderProperties = Set(
            Mirror(reflecting: InboxCacheDTO.Sender(
                displayName: nil,
                address: "someone@example.com",
                messageCount: 0,
                unreadCount: 0,
                starredCount: 0,
                importantCount: 0,
                newestReceivedAt: .now,
                oldestLoadedReceivedAt: .now,
                recentSubjects: [],
                categoryLabels: [],
                listUnsubscribeCount: 0,
                averageIntervalBetweenLoadedMessages: nil
            )).children.compactMap(\.label)
        )
        #expect(senderProperties.isDisjoint(with: derivedNames))
    }

    @Test("No proposal ever describes a sender in terms the evidence cannot support")
    func proposalWordingStaysWithinWhatMetadataCanShow() {
        let forbidden = ["spam", "useless", "junk", "safe to delete", "worthless", "guaranteed"]
        let proposals = [
            ProposalFixtures.proposal(for: ProposalFixtures.promotionalSender()),
            ProposalFixtures.proposal(for: ProposalFixtures.newsletterSender()),
            ProposalFixtures.proposal(for: ProposalFixtures.notificationSender()),
            ProposalFixtures.proposal(for: ProposalFixtures.lowVolumeSender()),
        ]

        for proposal in proposals {
            let text = (proposal.reasons.map(\.text) + [proposal.kind.displayName, proposal.kind.explanation])
                .joined(separator: " ")
                .lowercased()
            for word in forbidden {
                #expect(!text.contains(word), "A proposal called a sender \"\(word)\"")
            }
        }
    }
}

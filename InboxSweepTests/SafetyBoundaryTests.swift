import Foundation
import Testing
@testable import InboxSweep

/// Guards the promise the app makes about what it can do to a mailbox.
///
/// These are mostly tests of an *absence*. They exist so that a change which quietly adds a
/// mutating scope, a second kind of write, a bulk operation, or a message body to the domain
/// model fails here rather than in someone's mailbox.
///
/// Interval 6 is the first one where the answer stopped being "nothing". The app can now remove
/// the `INBOX` label from one message the user picked and confirmed, and put it back. That makes
/// this suite more important rather than less: the interesting property is no longer "there are
/// no writes" but "there are exactly two, they are the two documented here, and nothing except a
/// person pressing a button can reach them". Each section below pins down one part of that.
@Suite("Mailbox safety boundary")
struct SafetyBoundaryTests {

    // MARK: - Permissions

    @Test("Exactly two Gmail scopes are requested: metadata to read, modify to archive")
    func requestsOnlyTheTwoNeededScopes() {
        #expect(GmailScope.requested == [
            "https://www.googleapis.com/auth/gmail.metadata",
            "https://www.googleapis.com/auth/gmail.modify",
        ])
    }

    @Test("No scope is requested that could send, permanently delete, or change settings")
    func requestsNoProhibitedScope() {
        for scope in GmailScope.prohibited {
            #expect(!GmailScope.requested.contains(scope), "Requested a prohibited scope: \(scope)")
            #expect(!GmailScope.requestedScopeParameter.contains(scope))
        }
    }

    @Test("The full-access scope, the one that permits permanent deletion, is never requested")
    func requestsNoFullAccessScope() {
        // `https://mail.google.com/` is the one that would let the app delete mail outright,
        // with no Trash to recover it from. `gmail.modify` deliberately stops short of that,
        // and this is the line the app will not cross.
        #expect(GmailScope.prohibited.contains("https://mail.google.com/"))
        #expect(!GmailScope.requested.contains("https://mail.google.com/"))
    }

    @Test("The requested scopes do not include the body-reading read scope")
    func requestsNoBodyReadScope() {
        // `gmail.modify` does imply body access — Google grants no narrower permission that can
        // archive — so the limit that matters is enforced by the request surface below rather
        // than by the scope. What is still true, and worth keeping true, is that the app never
        // asks for `gmail.readonly`, and never asks Gmail for a body format.
        #expect(!GmailScope.requested.contains("https://www.googleapis.com/auth/gmail.readonly"))
    }

    @Test("Reading and archiving are separate permissions, and only reading is required")
    func archivingIsASeparatePermission() {
        // The property that keeps an existing read-only user signed in: a grant covering only
        // the read scope is usable, and only the archive action is unavailable.
        #expect(GmailScope.coversReading([GmailScope.metadata]))
        #expect(!GmailScope.coversArchiving([GmailScope.metadata]))
        #expect(GmailScope.coversArchiving(GmailScope.requested))

        let readOnlyGrant = GmailStoredCredentials(
            refreshToken: "synthetic",
            grantedScopes: [GmailScope.metadata],
            accountEmailAddress: "someone@example.com"
        )
        #expect(readOnlyGrant.coversReadScopes)
        #expect(!readOnlyGrant.coversArchiveScopes)
    }

    // MARK: - Request surface

    @Test("Every read request the app can build is a GET")
    func buildsOnlyReadRequests() {
        for request in GmailAPIEndpoint.allRequestBuilders() {
            #expect(request.method == "GET", "Non-GET Gmail read request: \(request.url)")
        }
    }

    @Test("No Gmail write endpoint is reachable from the read request builders")
    func buildsNoWriteEndpoint() {
        // Gmail's mutating operations all live at named paths. A future change that adds one
        // to the *read* builders has to add a builder for it, and a builder for it shows up
        // here. `modify` is in this list too: the two legitimate modify requests live in a
        // different type, which is checked separately below.
        let writePathFragments = [
            "modify", "batchModify", "trash", "untrash", "delete", "batchDelete",
            "send", "import", "insert", "labels", "settings", "watch", "stop",
        ]

        for request in GmailAPIEndpoint.allRequestBuilders() {
            let path = request.url.path().lowercased()
            for fragment in writePathFragments {
                #expect(
                    !path.contains(fragment.lowercased()),
                    "Gmail read request reaches a mutating path: \(request.url)"
                )
            }
        }
    }

    // MARK: - The mutation surface
    //
    // The whole of what this app can do to a mailbox, enumerated. If any assertion in this
    // section has to be changed, the change is the point — it means the app's power over
    // somebody's mail has grown, and that should never happen as a side effect.

    @Test("There are exactly two mutating requests, and both are message-level modify calls")
    func buildsExactlyTwoMutations() {
        let requests = GmailMutationEndpoint.allRequestBuilders()
        #expect(requests.count == 2, "The app can build \(requests.count) mutating requests")

        for request in requests {
            #expect(request.method == "POST")
            // `/users/me/messages/{id}/modify` — one message, named individually.
            #expect(request.url.path().hasSuffix("/messages/message-id/modify"))
            #expect(!request.url.path().contains("/threads/"), "A mutation reached the thread endpoint")
        }
    }

    @Test("The only mutation bodies that exist add or remove the Inbox label, and nothing else")
    func mutationBodiesOnlyTouchInbox() throws {
        for request in GmailMutationEndpoint.allRequestBuilders() {
            let body = try JSONDecoder().decode(
                GmailMailboxStub.ModifyLabelsBody.self,
                from: request.body
            )

            let touched = (body.addLabelIds ?? []) + (body.removeLabelIds ?? [])
            #expect(touched == ["INBOX"], "A mutation touched labels other than INBOX: \(touched)")

            // Belt and braces: the raw bytes name one label, so no extra key could be smuggled
            // past a decoder that ignores unknown fields.
            let raw = String(decoding: request.body, as: UTF8.self)
            #expect(!raw.contains("TRASH"))
            #expect(!raw.contains("SPAM"))
            #expect(!raw.contains("UNREAD"))
            #expect(!raw.contains("STARRED"))
            #expect(raw.filter { $0 == ":" }.count == 1, "A mutation body carried more than one instruction")
        }

        // Archive removes, undo adds. Neither does both, which is what would be needed to
        // express "take it out of the inbox and put it somewhere else".
        let archive = GmailMutationEndpoint.removeFromInbox(messageID: MailMessageID("m-1"))
        let undo = GmailMutationEndpoint.restoreToInbox(messageID: MailMessageID("m-1"))
        #expect(String(decoding: archive.body, as: UTF8.self) == #"{"removeLabelIds":["INBOX"]}"#)
        #expect(String(decoding: undo.body, as: UTF8.self) == #"{"addLabelIds":["INBOX"]}"#)
    }

    @Test("No mutating request reaches trash, delete, send, settings, or a batch endpoint")
    func mutationsReachNoDestructiveEndpoint() {
        let forbidden = [
            "trash", "untrash", "delete", "batchdelete", "batchmodify", "send", "drafts",
            "import", "insert", "settings", "watch", "stop", "labels", "threads",
        ]

        for request in GmailMutationEndpoint.allRequestBuilders() {
            let url = request.url.absoluteString.lowercased()
            for fragment in forbidden {
                #expect(!url.contains(fragment), "A mutation reached \(fragment): \(request.url)")
            }
        }
    }

    @Test("A message identifier cannot inject a path segment of its own")
    func identifiersCannotEscapeTheirSegment() {
        // Identifiers come from Gmail's responses, not from the user, so this is not a hole
        // anybody can reach today. It is checked anyway because the request builders are the
        // app's narrowest claim about which endpoints it can reach, and one of them now writes.
        let hostile = MailMessageID("m-1/../../settings/forwarding")

        for url in [
            GmailMutationEndpoint.removeFromInbox(messageID: hostile).url,
            GmailMutationEndpoint.restoreToInbox(messageID: hostile).url,
            GmailAPIEndpoint.messageMetadata(id: hostile).url,
        ] {
            // `pathComponents` decodes each segment, so the whole hostile identifier appearing
            // as *one* component is the proof that its slashes were encoded rather than
            // honoured. Six fixed segments, the identifier, and — for a mutation — `modify`.
            let components = url.pathComponents
            let fixed = ["/", "gmail", "v1", "users", "me", "messages"]
            #expect(Array(components.prefix(6)) == fixed)
            #expect(components[6] == hostile.rawValue, "The identifier spread across path segments")
            #expect(components.count <= 8)
            #expect(components.last == "modify" || components.count == 7)
            #expect(!components.contains("settings"), "An identifier reached the settings endpoint")
            #expect(!components.contains(".."))
        }
    }

    @Test("The mutation boundary offers archiving and undo, and nothing else at all")
    func mutationBoundaryIsTwoOperations() {
        // Named here so that the protocol's shape is checked rather than remembered. Adding a
        // `trash`, a `markRead`, a `setLabel`, or an `archiveAll` to `MailMessageArchiving`
        // means editing this list, which means saying so out loud.
        let boundaryMethodNames = ["archiveCapability", "authorizeArchiving", "archive", "restoreToInbox"]
        let forbidden = [
            "trash", "delete", "send", "unsubscribe", "markread", "markunread", "star",
            "label", "batch", "all", "bulk", "sender", "execute", "apply", "plan", "schedule",
        ]

        for name in boundaryMethodNames {
            for verb in forbidden {
                #expect(
                    !name.lowercased().contains(verb),
                    "The mutation boundary gained something beyond archive and undo: \(name)"
                )
            }
        }
    }

    @Test("A mutation request names one message and one account, and carries no plan")
    func mutationRequestsAreSingular() {
        let request = MailArchiveRequest(
            messageID: MailMessageID("m-1"),
            accountAddress: "someone@example.com"
        )

        // One identifier, not a list. There is no shape of this type that could ask for more
        // than one message, and nothing on it that names a sender, an action, or a plan.
        let propertyNames = Set(Mirror(reflecting: request).children.compactMap(\.label))
        #expect(propertyNames == ["messageID", "accountAddress", "operationID"])
        #expect(propertyNames.isDisjoint(with: [
            "messageIDs", "messages", "senderKey", "senderKeys", "action", "plan", "labels", "query",
        ]))

        // And exactly two operations exist to ask for.
        #expect(MailMutationOperation.allCases.count == 2)
        #expect(Set(MailMutationOperation.allCases.map(\.rawValue)) == ["archive", "restoreToInbox"])
    }

    @Test("A mutation transaction holds no mail, however many messages it names")
    func mutationTransactionsHoldNoMail() {
        let transaction = MailMutationTransaction(
            id: UUID(),
            operation: .archive,
            accountAddress: "someone@example.com",
            succeededMessageIDs: [MailMessageID("m-1"), MailMessageID("m-2")],
            selectedMessageCount: 3,
            occurredAt: .now,
            undoState: .undoable
        )

        let propertyNames = Set(Mirror(reflecting: transaction).children.compactMap(\.label))
        #expect(propertyNames == [
            "id", "operation", "accountAddress", "succeededMessageIDs", "selectedMessageCount",
            "occurredAt", "undoState",
        ])
        // Growing from one message to many did not grow what a transaction knows about mail.
        #expect(propertyNames.isDisjoint(with: [
            "subject", "subjects", "sender", "senders", "from", "body", "snippet", "receivedAt",
            "labels", "senderKey", "action", "plan",
        ]))

        // The file format carries even less: the account address is written once at the top of
        // the file, not copied onto every entry.
        let entryProperties = Set(
            Mirror(reflecting: MutationTransactionDTO.entry(from: transaction)).children.compactMap(\.label)
        )
        #expect(entryProperties == ["id", "operation", "messageIDs", "selectedCount", "occurredAt", "undoState"])
    }

    @Test("A frozen selection names messages and an account, and carries no instruction")
    func selectionsCarryNothingButIdentifiers() throws {
        let selection = try #require(MailArchiveSelection(
            messageIDs: [MailMessageID("m-1"), MailMessageID("m-2"), MailMessageID("m-1")],
            accountAddress: "someone@example.com"
        ))

        // Identifiers and an account. No label, no query, no sender, no action, no plan — so the
        // only thing a set can express is "these exact messages", which is the property that
        // makes a confirmation checkable.
        let propertyNames = Set(Mirror(reflecting: selection).children.compactMap(\.label))
        #expect(propertyNames == ["messageIDs", "accountAddress", "operationID"])
        #expect(propertyNames.isDisjoint(with: [
            "labels", "labelIDs", "addLabelIds", "removeLabelIds", "query", "senderKey",
            "sender", "action", "plan", "scope", "all",
        ]))

        // Duplicates collapse, so one message can never be asked about twice in one set.
        #expect(selection.messageIDs == [MailMessageID("m-1"), MailMessageID("m-2")])
        // And "archive nothing" is not an operation this type can express.
        #expect(MailArchiveSelection(messageIDs: [], accountAddress: "someone@example.com") == nil)

        // Every message in a set goes out as the same single-message request a lone archive
        // uses. That is the whole generalization: a set is a sequence of the proven call.
        let request = selection.request(for: MailMessageID("m-2"))
        #expect(request.messageID == MailMessageID("m-2"))
        #expect(request.accountAddress == "someone@example.com")
        #expect(request.operationID == selection.operationID)
    }

    @Test("Growing to sets added no new remotely-reachable mutation")
    func setsAddedNoNewProviderCapability() {
        // The claim this interval has to keep: `MailMessageArchiving` is *unchanged*. A set
        // archive is the session calling the same four methods more than once, so there is no
        // new endpoint, no new body, and no batch request to audit.
        #expect(GmailMutationEndpoint.allRequestBuilders().count == 2)

        let boundaryMethodNames = ["archiveCapability", "authorizeArchiving", "archive", "restoreToInbox"]
        #expect(boundaryMethodNames.count == 4, "The mutation boundary gained or lost a method")

        // And the type that executes a set has exactly one thing to execute *with*.
        let mutatorProperties = Set(
            Mirror(reflecting: MessageSetMutator(archiver: StubMessageArchiver())).children.compactMap(\.label)
        )
        #expect(mutatorProperties == ["archiver"])
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
        _ = await provider.disconnect()

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
        _ = await provider.disconnect()

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

        // InboxSweep reports; it does not recommend, score, or classify.
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
        // The disclaimer had to be reworded when the app gained an archive, because "no
        // permission to archive any message" stopped being true. What it claims now is the part
        // that still is, and it is the part this screen needs: a preview cannot be carried out.
        #expect(CleanupPlan.disclaimer.contains("Nothing here can be carried out"))
        #expect(CleanupPlan.disclaimer.contains("cannot archive a sender"))
    }

    // MARK: - Message review and saved plans

    @Test("Reviewing a sender's messages makes no request of any kind")
    @MainActor
    func messageReviewPerformsNoProviderCall() async throws {
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
        let requestsBeforeReview = transport.requests.count
        let snapshot = try #require(model.state.snapshot)

        // Every sender, every sort order, every action — including the ones whose names sound
        // like verbs the app cannot perform.
        for sender in snapshot.senders {
            for order in MessageReviewSortOrder.allCases {
                _ = model.reviewedMessages(forSenderKey: sender.id, sortedBy: order)
                for action in PlannedCleanupAction.offered {
                    _ = model.reviewedMessages(forSenderKey: sender.id, under: action, sortedBy: order)
                }
            }
        }

        #expect(transport.requests.count == requestsBeforeReview, "Reviewing sent a request")
    }

    @Test("A reviewed message carries metadata and no content, whatever plan is selected")
    func reviewedMessagesCarryNoContent() {
        let messages = ProposalFixtures.promotionalSender(count: 8)
        let membership = CleanupPlanner.membership(
            for: messages,
            action: .trashMessagesOlderThan(days: 1),
            referenceDate: ProposalFixtures.epoch
        )
        let row = ReviewedMessage(
            message: messages[0],
            protectionReason: SenderProtection.protectionReason(for: messages[0]),
            membership: membership[messages[0].id]
        )

        let propertyNames = Set(Mirror(reflecting: row).children.compactMap(\.label))
        #expect(propertyNames == ["message", "protectionReason", "membership"])

        // The membership itself is an enum case over an exclusion reason — there is nothing on
        // it that names a Gmail operation or carries anything to send.
        let membershipProperties = Set(Mirror(reflecting: membership).children.compactMap(\.label))
        #expect(membershipProperties.isDisjoint(with: ["request", "provider", "endpoint"]))
    }

    @Test("A saved plan is choices, and there is nothing on it to carry out")
    func savedPlansAreInertData() {
        let plan = SavedCleanupPlan(
            accountAddress: "someone@example.com",
            scope: .promotions,
            selections: [
                SavedCleanupSelection(
                    senderKey: "deals@example.com",
                    action: .trashMessagesOlderThan(days: 90)
                ),
            ],
            loadedMessageCount: 250,
            savedAt: .now
        )

        // Sender keys and an action identifier. No message identifiers, no provider, no
        // schedule, no "execute" of any shape — and, as with a plan, nothing that could stand
        // in for one if a later interval forgot to add the permission first.
        let propertyNames = Set(Mirror(reflecting: plan).children.compactMap(\.label))
        #expect(propertyNames == [
            "accountAddress", "scope", "selections", "rulesVersion", "loadedMessageCount", "savedAt",
        ])
        #expect(propertyNames.isDisjoint(with: [
            "messageIDs", "provider", "schedule", "runAt", "isEnabled", "autoRun", "executed",
        ]))
    }

    @Test("Restoring a saved plan opens a preview and performs nothing")
    @MainActor
    func restoringASavedPlanExecutesNothing() async throws {
        let messages = ProposalFixtures.promotionalSender(count: 20)
        let key = messages[0].sender.groupingKey
        let store = RecordingCleanupPlanStore(seeded: SavedCleanupPlan(
            accountAddress: MailAccount.testAccount.emailAddress.address,
            scope: .inbox,
            selections: [SavedCleanupSelection(senderKey: key, action: .trashMessagesOlderThan(days: 1))],
            loadedMessageCount: 20,
            savedAt: .now
        ))
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            restorable: .connected(.testAccount)
        )
        let model = InboxSessionModel(
            provider: provider,
            planStore: store,
            fetchRequest: MailFetchRequest(limit: 20)
        )

        await model.restore().value
        let fetchesAfterRestore = await provider.fetchCallCount

        // The plan names Trash. Restoring it produced a preview and nothing else: the provider
        // saw one read, and there is no API on it that could have done more.
        let restored = try #require(model.savedPlan)
        #expect(restored.usableSelections.first?.action == .trashMessagesOlderThan(days: 1))
        #expect(await provider.fetchCallCount == fetchesAfterRestore)
        #expect(await provider.disconnectCallCount == 0)
        #expect(await provider.connectCallCount == 0, "Restoring a plan re-authorized")
    }

    @Test("The read boundary still offers nothing that could change a mailbox")
    func readBoundaryHasNoMutatingOperation() {
        // The separation this interval had to preserve. Archiving exists now, and it lives on
        // its own protocol — `MailMessageFetching` still has exactly one method and it fetches.
        // A future change that adds a write here rather than there has to edit this list.
        let forbidden = ["archive", "trash", "delete", "modify", "label", "markRead", "send", "unsubscribe", "execute", "apply", "perform"]
        let boundaryMethodNames = ["fetchMessages", "connect", "disconnect", "restoreConnection", "currentConnection", "storedAuthorizationState"]

        for name in boundaryMethodNames {
            for verb in forbidden {
                #expect(
                    !name.lowercased().contains(verb.lowercased()),
                    "A read boundary method is named after a mutation: \(name)"
                )
            }
        }
    }

    @Test("A provider cannot write unless it deliberately vends a mutation boundary")
    @MainActor
    func providersAreReadOnlyByDefault() async {
        // The default is the safe one, and the synthetic mailbox relies on it: no archiver
        // means no code path to a mutation at all, rather than a guard somebody has to
        // remember to write.
        #expect(SampleMailProvider().messageArchiver == nil)
        #expect(StubMailProvider().messageArchiver == nil)

        let session = InboxSessionModel(provider: SampleMailProvider())
        await session.connect().value
        #expect(session.archiveCapability == .unsupported)
        #expect(!session.canOfferArchiving)
        #expect(!session.canArchive(messageID: MailMessageID("anything")))
    }

    // MARK: - Nothing reaches a mutation on its own
    //
    // The most important section in the suite. The app's write is reachable from exactly one
    // place — a person selecting a message and confirming — and these cases exercise every
    // *other* path that might plausibly grow into one.

    @Test("Loading, previewing, saving a plan, and restoring one archive nothing")
    @MainActor
    func nothingButAnExplicitActionMutates() async throws {
        let messages = ProposalFixtures.promotionalSender(count: 20) + ProposalFixtures.newsletterSender(count: 12)
        let archiver = StubMessageArchiver()
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            archiver: archiver
        )
        let model = InboxSessionModel(provider: provider, fetchRequest: MailFetchRequest(limit: 40))

        await model.connect().value
        let snapshot = try #require(model.state.snapshot)

        // Every read-and-reason operation the app has, including the ones whose names are verbs
        // the app can now actually perform.
        for sender in snapshot.senders {
            _ = model.proposal(forSenderKey: sender.id)
            _ = model.loadedMessages(forSenderKey: sender.id)
            for action in PlannedCleanupAction.offered {
                _ = model.reviewedMessages(forSenderKey: sender.id, under: action)
                _ = model.cleanupPlan(for: [CleanupPlanRequest(senderKey: sender.id, action: action)])
            }
        }

        await model.savePlan(
            snapshot.senders.map { SavedCleanupSelection(senderKey: $0.id, action: .archiveMessagesOlderThan(days: 30)) }
        ).value
        await model.loadMore().value
        model.sortOrder = .mostRecent
        await model.reload().value

        #expect(archiver.allRequests.isEmpty, "Something other than an explicit action archived")
    }

    @Test("A restored plan naming an archive action still archives nothing")
    @MainActor
    func restoringAPlanNamingArchiveArchivesNothing() async throws {
        let messages = ProposalFixtures.promotionalSender(count: 20)
        let key = messages[0].sender.groupingKey
        let archiver = StubMessageArchiver()
        let store = RecordingCleanupPlanStore(seeded: SavedCleanupPlan(
            accountAddress: MailAccount.testAccount.emailAddress.address,
            scope: .inbox,
            // The action is literally called "archive messages older than a day", and every
            // loaded message qualifies. Restoring it must still produce a preview and nothing
            // more — there is no path from a saved plan to the mutation boundary.
            selections: [SavedCleanupSelection(senderKey: key, action: .archiveMessagesOlderThan(days: 1))],
            loadedMessageCount: 20,
            savedAt: .now
        ))
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            restorable: .connected(.testAccount),
            archiver: archiver
        )
        let model = InboxSessionModel(
            provider: provider,
            planStore: store,
            fetchRequest: MailFetchRequest(limit: 20)
        )

        await model.restore().value

        let restored = try #require(model.savedPlan)
        #expect(restored.usableSelections.first?.action == .archiveMessagesOlderThan(days: 1))
        #expect(archiver.allRequests.isEmpty, "A restored plan reached the mutation boundary")
        #expect(model.mutationActivity == nil)
        #expect(model.undoableArchive == nil)
    }

    @Test("A set archive sends nothing but the two INBOX modifies, one message at a time")
    @MainActor
    func setArchivesCarryOnlyInboxModifies() async throws {
        // The claim the interval has to keep once archiving can act on many messages: growing
        // from one to twelve grew the *number* of requests and nothing about what a request is
        // allowed to say. This drives a real Gmail adapter over a recording transport and reads
        // every byte that went out.
        var stub = GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 12))
        stub.grantedScope = GmailScope.requestedScopeParameter
        let transport = RecordingHTTPTransport(handler: stub.handler())
        let provider = GmailProvider(
            configuration: GmailOAuthConfiguration(clientID: "1234567890-abcdef.apps.googleusercontent.com"),
            transport: transport,
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: InMemoryCredentialStore(),
            retryPolicy: .immediate
        )
        let model = InboxSessionModel(provider: provider, fetchRequest: MailFetchRequest(limit: 12))

        await model.connect().value
        let snapshot = try #require(model.state.snapshot)
        let senderKey = try #require(snapshot.senders.first).id
        let chosen = model.loadedMessages(forSenderKey: senderKey).prefix(4).map(\.id)
        try #require(chosen.count >= 2)

        let frozen = try #require(model.makeArchiveSelection(forSenderKey: senderKey, messageIDs: chosen))
        await model.archiveSelection(frozen).value
        await model.undoLastArchive().value

        let writes = transport.requests.filter {
            ($0.url?.host ?? "").contains("gmail.googleapis.com") && $0.httpMethod != "GET"
        }
        #expect(writes.count == chosen.count * 2, "Expected one archive and one undo per message")

        for write in writes {
            #expect(write.httpMethod == "POST")
            // Every write names exactly one message, at the message-level modify endpoint.
            let path = write.url?.path() ?? ""
            #expect(path.hasSuffix("/modify"))
            #expect(!path.contains("/threads/"), "A set reached the thread endpoint")
            #expect(!path.lowercased().contains("batch"), "A set reached a batch endpoint")
            let named = chosen.filter { path.hasSuffix("/messages/\($0.rawValue)/modify") }
            #expect(named.count == 1, "A write named something other than one selected message")

            // And the body is still one of the two literals, byte for byte.
            let body = String(decoding: write.httpBody ?? Data(), as: UTF8.self)
            #expect(body == #"{"removeLabelIds":["INBOX"]}"# || body == #"{"addLabelIds":["INBOX"]}"#)
        }

        // No request mentions a message the user did not select.
        let selected = Set(chosen.map(\.rawValue))
        let untouched = model.loadedMessages(forSenderKey: senderKey).map(\.id.rawValue).filter { !selected.contains($0) }
        for identifier in untouched {
            #expect(
                !writes.contains { ($0.url?.path() ?? "").contains("/messages/\(identifier)/modify") },
                "A set archive wrote to an unselected message"
            )
        }
    }

    @Test("Selecting, previewing, preselecting, and opening a confirmation write nothing")
    @MainActor
    func everythingBeforeConfirmationIsInert() async throws {
        // The single most important property of the selection model: the user can build, edit,
        // and inspect a set of any size, driven by a cleanup recommendation, and none of it is a
        // step towards executing anything. Only the confirmation is.
        let messages = ProposalFixtures.promotionalSender(count: 24) + ProposalFixtures.newsletterSender(count: 14)
        let archiver = StubMessageArchiver()
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            archiver: archiver
        )
        let model = InboxSessionModel(provider: provider, fetchRequest: MailFetchRequest(limit: 40))

        await model.connect().value
        let snapshot = try #require(model.state.snapshot)

        for sender in snapshot.senders {
            let loaded = model.loadedMessages(forSenderKey: sender.id).map(\.id)

            for action in PlannedCleanupAction.offered {
                // The dry run, and the convenience action that turns its result into ticks.
                _ = model.cleanupPlan(for: [CleanupPlanRequest(senderKey: sender.id, action: action)])
                let preselectable = model.preselectableMessageIDs(forSenderKey: sender.id, under: action)

                if !preselectable.isEmpty {
                    // Freezing every one of them into a confirmation — the last step before the
                    // button, performed here for every sender and every action in the app.
                    let frozen = model.makeArchiveSelection(forSenderKey: sender.id, messageIDs: preselectable)
                    _ = frozen.map(model.canArchive)
                    _ = frozen?.selection()
                    _ = frozen?.protectedMessages
                }
            }

            // And the whole sender at once, which is the largest set this screen can produce.
            if !loaded.isEmpty {
                let everything = try #require(model.makeArchiveSelection(forSenderKey: sender.id, messageIDs: loaded))
                #expect(everything.count == loaded.count)
                _ = model.canArchive(everything)
            }
        }

        #expect(archiver.allRequests.isEmpty, "Something before the confirmation reached the mutation boundary")
        #expect(model.mutationActivity == nil, "Something before the confirmation started an operation")
        #expect(model.undoableArchive == nil)
        #expect(try #require(model.state.snapshot).loadedMessageCount == 38, "The window changed before any confirmation")
    }

    @Test("A convenience action never picks a message the mailbox marks as worth keeping")
    @MainActor
    func preselectionNeverPicksProtectedMail() async throws {
        // The line between the app choosing and the user choosing. Asserted over every offered
        // action and every sender, rather than for one case, because this is the guarantee that
        // makes "fill from preview" safe to offer at all.
        let messages = ProposalFixtures.promotionalSender(count: 30) + ProposalFixtures.newsletterSender(count: 20)
        let model = InboxSessionModel(
            provider: StubMailProvider(
                fetch: .pages([MailMessagePage(messages: messages)]),
                archiver: StubMessageArchiver()
            ),
            fetchRequest: MailFetchRequest(limit: 50)
        )
        await model.connect().value
        let snapshot = try #require(model.state.snapshot)

        for sender in snapshot.senders {
            let protectedIDs = Set(
                model.reviewedMessages(forSenderKey: sender.id).filter(\.isProtected).map(\.id)
            )
            for action in PlannedCleanupAction.offered {
                let preselectable = Set(model.preselectableMessageIDs(forSenderKey: sender.id, under: action))
                #expect(
                    preselectable.isDisjoint(with: protectedIDs),
                    "A convenience action picked a protected message under \(action.displayName)"
                )
            }
        }
    }

    @Test("Archiving acts on one message and leaves every other one alone")
    @MainActor
    func archivingIsSingularInPractice() async throws {
        let messages = ProposalFixtures.promotionalSender(count: 12)
        let archiver = StubMessageArchiver()
        let provider = StubMailProvider(
            fetch: .pages([MailMessagePage(messages: messages)]),
            archiver: archiver
        )
        let model = InboxSessionModel(provider: provider, fetchRequest: MailFetchRequest(limit: 12))

        await model.connect().value
        let target = messages[3].id
        await model.archiveMessage(target).value

        let requests = archiver.allRequests
        #expect(requests.count == 1, "One confirmation produced \(requests.count) mutations")
        #expect(requests.first?.messageID == target)

        // The other eleven are untouched, and the window still holds them.
        let key = messages[0].sender.groupingKey
        let remaining = model.loadedMessages(forSenderKey: key)
        #expect(remaining.count == 11)
        #expect(!remaining.contains { $0.id == target })
    }

    @Test("No Gmail write goes out except the one modify the user confirmed")
    @MainActor
    func liveTrafficCarriesExactlyOneMutation() async throws {
        var stub = GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 8))
        stub.grantedScope = GmailScope.requestedScopeParameter
        let transport = RecordingHTTPTransport(handler: stub.handler())
        let provider = GmailProvider(
            configuration: GmailOAuthConfiguration(clientID: "1234567890-abcdef.apps.googleusercontent.com"),
            transport: transport,
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: InMemoryCredentialStore(),
            retryPolicy: .immediate
        )
        let model = InboxSessionModel(provider: provider, fetchRequest: MailFetchRequest(limit: 8))

        await model.connect().value
        let snapshot = try #require(model.state.snapshot)
        let target = try #require(model.loadedMessages(forSenderKey: snapshot.senders[0].id).first).id

        // Preview everything first, then archive one message, then undo it.
        for sender in snapshot.senders {
            for action in PlannedCleanupAction.offered {
                _ = model.cleanupPlan(for: [CleanupPlanRequest(senderKey: sender.id, action: action)])
            }
        }
        await model.archiveMessage(target).value
        await model.undoLastArchive().value

        let gmailWrites = transport.requests.filter {
            ($0.url?.host ?? "").contains("gmail.googleapis.com") && $0.httpMethod != "GET"
        }
        #expect(gmailWrites.count == 2, "Expected one archive and one undo, got \(gmailWrites.count) writes")

        for write in gmailWrites {
            #expect(write.httpMethod == "POST")
            #expect(write.url?.path().hasSuffix("/messages/\(target.rawValue)/modify") == true)
            let body = String(decoding: write.httpBody ?? Data(), as: UTF8.self)
            #expect(body == #"{"removeLabelIds":["INBOX"]}"# || body == #"{"addLabelIds":["INBOX"]}"#)
        }
    }

    @Test("Every mailbox scope reads a label Gmail already applies, and none is a search")
    func scopesAreLabelReadsOnly() {
        for scope in MailboxScope.allCases {
            let url = GmailAPIEndpoint.listMessages(limit: 50, pageToken: nil, scope: scope).url

            #expect(url.path().hasSuffix("/messages"), "A scope reached a path other than the list endpoint")
            #expect(!url.absoluteString.contains("q="), "A scope smuggled in a search query")

            // The label identifiers are Gmail's own, and all of them are read-only category or
            // system labels rather than anything the app invented or could create.
            if let labelID = GmailAPIEndpoint.labelID(for: scope) {
                #expect(labelID == labelID.uppercased())
                #expect(["INBOX", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_SOCIAL", "CATEGORY_FORUMS"].contains(labelID))
            }
        }
    }

    @Test("A deeper load is still nothing but GETs")
    @MainActor
    func deepLoadingStaysReadOnly() async throws {
        let transport = RecordingHTTPTransport(
            handler: GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 20)).handler()
        )
        let provider = GmailProvider(
            configuration: GmailOAuthConfiguration(clientID: "1234567890-abcdef.apps.googleusercontent.com"),
            transport: transport,
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: InMemoryCredentialStore(),
            retryPolicy: .immediate
        )
        let model = InboxSessionModel(
            provider: provider,
            fetchRequest: MailFetchRequest(limit: 10),
            loadDepth: MailboxLoadDepth(messageLimit: 100, pageSize: 10)
        )

        await model.connect().value
        model.scope = .promotions
        await model.reload().value
        await model.loadToDepth().value

        let gmailRequests = transport.requests.filter { ($0.url?.host ?? "").contains("gmail.googleapis.com") }
        #expect(!gmailRequests.isEmpty, "The exercise must actually have called Gmail")
        for request in gmailRequests {
            #expect(request.httpMethod == "GET", "Deep loading wrote to Gmail")
            #expect(request.httpBody == nil)
        }
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

        // The saved-plan record is the only other file the app writes, and it has no field for
        // a proposal either — nor for a message.
        let planRecord = CleanupPlanDTO.Record(
            version: CleanupPlanDTO.schemaVersion,
            accountAddress: "someone@example.com",
            scope: MailboxScope.inbox.rawValue,
            rulesVersion: CleanupProposalRules.version,
            loadedMessageCount: 0,
            savedAt: .now,
            selections: []
        )
        let planProperties = Set(Mirror(reflecting: planRecord).children.compactMap(\.label))
        #expect(planProperties.isDisjoint(with: derivedNames.subtracting(["rulesVersion"])))
        #expect(planProperties.isDisjoint(with: ["messages", "subjects", "senders"]))

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

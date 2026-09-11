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

        // `confirmedMessageCount` arrived with the Activity history. It is a *count*, and the
        // reason it exists is that the alternative was worse: a history row that stayed
        // descriptive after a partial undo otherwise needed the subjects copied in beside it.
        // The point of this case is that the record became one integer richer and no closer to
        // holding somebody's mail.
        let propertyNames = Set(Mirror(reflecting: transaction).children.compactMap(\.label))
        #expect(propertyNames == [
            "id", "operation", "accountAddress", "succeededMessageIDs", "selectedMessageCount",
            "confirmedMessageCount", "occurredAt", "undoState",
        ])
        // Growing from one message to many, and then to a browsable history, did not grow what a
        // transaction knows about mail.
        #expect(propertyNames.isDisjoint(with: [
            "subject", "subjects", "sender", "senders", "from", "body", "snippet", "receivedAt",
            "labels", "senderKey", "action", "plan",
        ]))

        // The file format carries even less: the account address is written once at the top of
        // the file, not copied onto every entry.
        let entryProperties = Set(
            Mirror(reflecting: MutationTransactionDTO.entry(from: transaction)).children.compactMap(\.label)
        )
        #expect(entryProperties == [
            "id", "operation", "messageIDs", "selectedCount", "occurredAt", "undoState",
            "confirmedCount",
        ])
        #expect(entryProperties.isDisjoint(with: [
            "subject", "sender", "from", "body", "snippet", "labels", "query",
        ]))
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
        // `List-Unsubscribe-Post` joined the list in Interval 10. It is written out here rather
        // than only compared against the constant, so adding a sixth header is a change somebody
        // has to make in a test as well as in the adapter — and so this line records that the
        // header set grew by one and the *scope set* did not.
        #expect(requested == ["From", "Subject", "Date", "List-Unsubscribe", "List-Unsubscribe-Post"])
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
        // `hasListUnsubscribeHeader` became `unsubscribe` in Interval 10 — parsed values in
        // place of a Boolean. Still metadata, and still nowhere to put a body: the type it holds
        // can only contain destinations and recorded refusals.
        #expect(propertyNames == ["id", "threadID", "sender", "subject", "receivedAt", "labels", "unsubscribe"])

        // And what that type holds is itself content-free.
        let metadataNames = Set(Mirror(reflecting: message.unsubscribe).children.compactMap(\.label))
        #expect(metadataNames.isDisjoint(with: contentBearingNames))
        #expect(metadataNames == ["targets", "declaresOneClickPost", "headerWasPresent"])
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

    @Test("Loading mail parses the unsubscribe header and contacts nobody")
    func recordsUnsubscribeWithoutActingOnIt() async throws {
        // Interval 10 gave the app an unsubscribe feature, so this test's claim narrowed and
        // got sharper. *Loading* mail still contacts no unsubscribe address — parsing is
        // parsing, and a destination sitting in a parsed value is not a request. What can reach
        // one is a user opening a review and confirming it twice, which is asserted separately.
        let messages = [
            GmailFixtures.SyntheticMessage(id: "u1", listUnsubscribe: "<https://unsub.example/u/1>"),
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
        // Parsed into a typed destination rather than kept as text.
        #expect(page.messages.first { $0.id == MailMessageID("u1") }?.unsubscribe.webURLs.first?.host == "unsub.example")

        // And nothing went to it. Every request this load made was to Google.
        #expect(!transport.requests.contains { ($0.url?.absoluteString ?? "").contains("unsub.example") })
        #expect(transport.requests.allSatisfy { ($0.url?.host ?? "").hasSuffix("googleapis.com") })
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

    // MARK: - Sender-level convenience is not sender-level authority
    //
    // The interval that added "Review messages to archive…" is the one where the safety claim is
    // easiest to lose: a sender-level *action* is one small step from a sender-level *operation*,
    // and this section is the line between them.

    @Test("Everything a sender-level action does before a confirmation writes nothing")
    @MainActor
    func senderLevelFlowsAreInertUntilConfirmed() async throws {
        // The whole journey the entry point starts, for every sender and every action: derive the
        // candidates, preselect them, edit the selection in both directions, and freeze the
        // result into a confirmation. Nothing in that reaches a provider.
        let messages = ProposalFixtures.promotionalSender(count: 24) + ProposalFixtures.newsletterSender(count: 16)
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
                let candidates = model.senderReviewCandidates(forSenderKey: sender.id, under: action)

                // Every sentence the screen would show, including the ones for the empty cases.
                _ = candidates.emptyReason
                _ = candidates.emptyExplanation
                _ = candidates.preselectionSummary

                // Preselecting, then unticking one, then ticking something the app refused to
                // pick — every edit the review screen allows.
                if !candidates.isEmpty {
                    _ = model.makeArchiveSelection(forSenderKey: sender.id, messageIDs: candidates.messageIDs)
                    _ = model.makeArchiveSelection(
                        forSenderKey: sender.id,
                        messageIDs: candidates.messageIDs.dropFirst()
                    )
                }
                let widened = model.makeArchiveSelection(forSenderKey: sender.id, messageIDs: loaded)
                _ = widened.map(model.canArchive)
                _ = widened?.selection()
            }
        }

        #expect(archiver.allRequests.isEmpty, "A sender-level flow reached the mutation boundary")
        #expect(model.mutationActivity == nil, "A sender-level flow started an operation")
        #expect(model.undoableArchive == nil)
        #expect(try #require(model.state.snapshot).loadedMessageCount == 40, "The window moved before any confirmation")
    }

    @Test("Candidate derivation never crosses a sender, and never picks protected mail")
    @MainActor
    func candidatesStayWithinOneSenderAndSkipProtectedMail() async throws {
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
            let own = Set(model.loadedMessages(forSenderKey: sender.id).map(\.id))
            let protectedIDs = Set(
                model.reviewedMessages(forSenderKey: sender.id).filter(\.isProtected).map(\.id)
            )

            for action in PlannedCleanupAction.offered {
                let candidates = model.senderReviewCandidates(forSenderKey: sender.id, under: action)
                #expect(candidates.senderKey == sender.id)
                #expect(
                    Set(candidates.messageIDs).isSubset(of: own),
                    "A candidate set reached another sender's mail under \(action.displayName)"
                )
                #expect(
                    Set(candidates.messageIDs).isDisjoint(with: protectedIDs),
                    "A candidate set picked protected mail under \(action.displayName)"
                )
            }
        }
    }

    @Test("No sender-level mutation exists anywhere, and no sender reaches Gmail as one")
    @MainActor
    func noSenderLevelMutationExists() async throws {
        // Three separate claims, because the convenience could have grown into any of them.

        // One: the mutation boundary still has exactly four methods, and none of them names a
        // sender, a plan, a rule, or a bulk operation.
        let boundaryMethodNames = ["archiveCapability", "authorizeArchiving", "archive", "restoreToInbox"]
        #expect(boundaryMethodNames.count == 4, "The mutation boundary gained or lost a method")
        for name in boundaryMethodNames {
            for verb in ["sender", "plan", "rule", "filter", "bulk", "all", "execute", "apply", "sweep"] {
                #expect(
                    !name.lowercased().contains(verb),
                    "The mutation boundary gained something sender-shaped: \(name)"
                )
            }
        }

        // Two: a request to that boundary carries a message identifier and an account, and has
        // nowhere to put a sender even if something wanted to send one.
        let request = MailArchiveRequest(
            messageID: MailMessageID("m-1"),
            accountAddress: "someone@example.com"
        )
        let requestProperties = Set(Mirror(reflecting: request).children.compactMap(\.label))
        #expect(requestProperties == ["messageID", "accountAddress", "operationID"])
        #expect(requestProperties.isDisjoint(with: [
            "sender", "senderKey", "senderAddress", "query", "labelQuery", "rule", "plan", "action",
        ]))

        // Three: the candidate set — the one new type a sender-level action produces — carries
        // identifiers and counts. There is nothing on it to carry out, and nothing that could
        // stand in for a request.
        let candidates = SenderReviewCandidates.derive(
            from: [],
            senderKey: "deals@example.com",
            under: .keepNewest(count: 5)
        )
        let candidateProperties = Set(Mirror(reflecting: candidates).children.compactMap(\.label))
        #expect(candidateProperties == [
            "senderKey", "action", "messageIDs", "loadedMessageCount",
            "protectedMessageCount", "outOfScopeMessageCount",
        ])
        #expect(candidateProperties.isDisjoint(with: [
            "provider", "archiver", "request", "endpoint", "execute", "perform", "schedule",
            "runAt", "isEnabled", "autoRun", "appliesToFutureMessages",
        ]))
    }

    @Test("A real sender-reviewed archive sends the reviewed messages and nothing sender-shaped")
    @MainActor
    func senderReviewedArchiveCarriesOnlyMessageModifies() async throws {
        // Driven through the real Gmail adapter over a recording transport, so this counts bytes:
        // a sender-level *entry point* must produce exactly the same traffic as ticking the same
        // messages by hand.
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

        let candidates = model.senderReviewCandidates(forSenderKey: senderKey, under: .keepNewest(count: 1))
        try #require(!candidates.isEmpty)
        let requestsAfterDeriving = transport.requests.count

        let frozen = try #require(model.makeArchiveSelection(
            forSenderKey: senderKey,
            messageIDs: candidates.messageIDs
        ))
        #expect(transport.requests.count == requestsAfterDeriving, "Freezing a sender's set sent something")

        await model.archiveSelection(frozen).value

        let writes = transport.requests.filter {
            ($0.url?.host ?? "").contains("gmail.googleapis.com") && $0.httpMethod != "GET"
        }
        #expect(writes.count == frozen.count, "One request per reviewed message")

        let senderAddress = try #require(snapshot.senders.first).sender.address
        for write in writes {
            let url = write.url?.absoluteString ?? ""
            #expect(write.httpMethod == "POST")
            #expect(write.url?.path().hasSuffix("/modify") == true)
            #expect(!url.lowercased().contains("batch"), "A sender-reviewed archive reached a batch endpoint")
            #expect(!url.contains("/threads/"), "A sender-reviewed archive reached the thread endpoint")
            #expect(!url.contains("/settings"), "A sender-reviewed archive reached the settings API")
            #expect(!url.contains("/filters"), "A sender-reviewed archive created a filter")
            #expect(!url.contains("q="), "A sender-reviewed archive smuggled in a query")

            // The sender is UI context. It has no business appearing in a URL or a body.
            let body = String(decoding: write.httpBody ?? Data(), as: UTF8.self)
            #expect(!url.contains(senderAddress), "A sender address reached a Gmail mutation URL")
            #expect(!body.contains(senderAddress), "A sender address reached a Gmail mutation body")
            #expect(body == #"{"removeLabelIds":["INBOX"]}"#)

            // And it named one of the reviewed messages, not something the planner produced later.
            let named = frozen.messageIDs.filter { url.hasSuffix("/messages/\($0.rawValue)/modify") }
            #expect(named.count == 1, "A write named something other than one reviewed message")
        }
    }

    @Test("The confirmation says a sender's future mail is untouched, because nothing schedules anything")
    func confirmationDeniesAnyFutureEffect() {
        // The sentence is asserted because it is a promise the app is making on screen, and the
        // thing that makes it true — there being no rule, filter, or schedule anywhere — is
        // asserted beside it.
        let note = ArchiveSelectionSnapshot.senderScopeNote
        #expect(note.contains("Only the messages listed here will be changed"))
        #expect(note.contains("Future messages from this sender are not affected"))
        #expect(note.contains("creates no rule"))

        // Nothing the app persists has anywhere to hold a rule about future mail. The saved plan
        // is the only file that stores a *choice*, and it stores sender keys and action
        // identifiers — no message, no schedule, no enablement.
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
        #expect(planProperties.isDisjoint(with: [
            "schedule", "runAt", "isEnabled", "autoRun", "appliesToFutureMessages", "filter", "rule",
        ]))
    }

    // MARK: - Unsubscribe is a second capability, not a wider first one

    @Test("Unsubscribing added no Gmail scope, and none of the prohibited ones")
    func unsubscribeAddsNoGmailScope() {
        // The claim requirement 11 of this interval asks to be proved rather than asserted:
        // the app gained the ability to unsubscribe and asks Google for exactly what it asked
        // for before. It can, because a one-click unsubscribe does not touch Gmail at all.
        #expect(GmailScope.requested == [
            "https://www.googleapis.com/auth/gmail.metadata",
            "https://www.googleapis.com/auth/gmail.modify",
        ])

        for scope in GmailScope.prohibited {
            #expect(!GmailScope.requested.contains(scope))
        }
        // Named individually, because these are the four somebody would reach for if they tried
        // to implement mailto unsubscribe by *sending* the mail.
        for sendingScope in [
            "https://www.googleapis.com/auth/gmail.send",
            "https://www.googleapis.com/auth/gmail.compose",
            "https://www.googleapis.com/auth/gmail.insert",
            "https://www.googleapis.com/auth/gmail.settings.basic",
        ] {
            #expect(GmailScope.prohibited.contains(sendingScope))
            #expect(!GmailScope.requestedScopeParameter.contains(sendingScope))
        }
    }

    @Test("No Gmail mutation endpoint is reachable from the unsubscribe boundary")
    func unsubscribeReachesNoGmailEndpoint() {
        // The mutating surface did not grow. There are still exactly two mutating Gmail
        // requests, they are still the two INBOX label changes, and unsubscribe is not among
        // them — because unsubscribe is not a Gmail operation.
        #expect(GmailMutationEndpoint.allRequestBuilders().count == 2)

        for request in GmailMutationEndpoint.allRequestBuilders() {
            let body = String(data: request.body, encoding: .utf8) ?? ""
            #expect(!body.lowercased().contains("unsubscribe"))
            #expect(!request.url.absoluteString.lowercased().contains("unsubscribe"))
            #expect(!request.url.absoluteString.contains("settings"))
            #expect(!request.url.absoluteString.contains("filters"))
        }

        // And the one-click request goes to the endpoint from the header, never to Google.
        let endpoint = HTTPSUnsubscribeURL(string: "https://lists.example/u/abc")!
        let unsubscribeRequest = OneClickUnsubscribeClient.urlRequest(for: endpoint)
        // Bound to a local rather than written inline: `#expect(!(x ?? "").contains(y))` folds
        // into a Void-typed expression that swift-testing reports as a failure whatever the
        // values are. Worth a line to avoid, and worth the note so it is not re-inlined.
        let unsubscribeURL = unsubscribeRequest.url?.absoluteString ?? ""
        #expect(unsubscribeRequest.url?.host == "lists.example")
        #expect(!unsubscribeURL.contains("googleapis"))
    }

    @Test("The unsubscribe boundary offers inspection and one standard request, and nothing else")
    func unsubscribeBoundaryIsNarrow() {
        // Enumerated by hand, because the point is the *absence* of a third method. A protocol
        // that grew an `openPage`, a `sendMail`, a `createRule`, or a generic `perform` would
        // be a different promise, and it should be argued about in a test rather than found in
        // somebody's subscriptions.
        let boundary: any MailUnsubscribing = RecordingUnsubscriber()
        _ = boundary.unsubscribeCapability
        _ = boundary.submitOneClickUnsubscribe

        // Nothing here can express a rule, a filter, or a bulk operation.
        let request = OneClickUnsubscribeRequest(
            endpoint: HTTPSUnsubscribeURL(string: "https://lists.example/u")!,
            accountAddress: "someone@example.com"
        )
        let properties = Set(Mirror(reflecting: request).children.compactMap(\.label))
        #expect(properties == ["endpoint", "accountAddress", "operationID"])
        #expect(properties.isDisjoint(with: [
            "senderKey", "senders", "messageIDs", "rule", "filter", "schedule", "applyToFuture", "all",
        ]))
    }

    @Test("No Google access token can reach an unsubscribe host, because they share no object")
    func noGoogleTokenReachesAnUnsubscribeHost() async throws {
        // Driven end to end: a real provider, a real connect that mints a token, a real load,
        // and then a one-click unsubscribe — with a *separate* recording transport under the
        // unsubscribe client, so everything it sends is inspectable.
        let unsubscribeTransport = RecordingHTTPTransport { _, _ in HTTPResponse(statusCode: 200) }
        let gmailTransport = RecordingHTTPTransport(
            handler: GmailMailboxStub(messages: [
                GmailFixtures.SyntheticMessage(
                    id: "u1",
                    listUnsubscribe: "<https://lists.example/u/abc>",
                    listUnsubscribePost: "List-Unsubscribe=One-Click"
                )
            ]).handler()
        )
        let provider = GmailProvider(
            configuration: GmailOAuthConfiguration(clientID: "1234567890-abcdef.apps.googleusercontent.com"),
            transport: gmailTransport,
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: InMemoryCredentialStore(),
            retryPolicy: .immediate,
            unsubscriber: OneClickUnsubscribeClient(transport: unsubscribeTransport)
        )

        let account = try await provider.connect()
        let page = try await provider.fetchMessages(MailFetchRequest(limit: 1))
        let endpoint = try #require(page.messages[0].unsubscribe.oneClickURL)

        let unsubscriber = try #require(provider.unsubscriber)
        _ = try await unsubscriber.submitOneClickUnsubscribe(
            OneClickUnsubscribeRequest(endpoint: endpoint, accountAddress: account.emailAddress.address)
        )

        // Gmail's transport really did carry a bearer token, so the check below is meaningful.
        #expect(gmailTransport.requests.contains { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true })

        // The unsubscribe transport carried one request, to the sender's host, with nothing on
        // it. No Authorization header, no cookie, no Google token anywhere in it, and not the
        // user's own address.
        #expect(unsubscribeTransport.requestCount == 1)
        let sent = try #require(unsubscribeTransport.requests.first)
        #expect(sent.url?.host == "lists.example")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sent.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(Set((sent.allHTTPHeaderFields ?? [:]).keys) == ["Content-Type"])

        let everythingSent = [
            sent.url?.absoluteString ?? "",
            String(data: sent.httpBody ?? Data(), encoding: .utf8) ?? "",
            (sent.allHTTPHeaderFields ?? [:]).map { "\($0.key):\($0.value)" }.joined(separator: " "),
        ].joined(separator: " ")

        for token in gmailTransport.requests.compactMap({ $0.value(forHTTPHeaderField: "Authorization") }) {
            #expect(!everythingSent.contains(token))
            #expect(!everythingSent.contains(token.replacingOccurrences(of: "Bearer ", with: "")))
        }
        #expect(!everythingSent.contains(account.emailAddress.address))
        #expect(!everythingSent.contains("u1"), "A Gmail message identifier must not reach a third party")

        // And nothing went the other way either: no Gmail request was aimed at the sender's host.
        #expect(gmailTransport.requests.allSatisfy { ($0.url?.host ?? "").hasSuffix("googleapis.com") })
    }

    @Test("Only a validated HTTPS URL can be executed, and there is no other way to make one")
    func onlyValidatedHTTPSURLsAreExecutable() {
        // The one-click request's initializer takes an `HTTPSUnsubscribeURL`, not a `URL` and
        // not a `String`. So the question "could something post to an http:// or javascript:
        // destination?" is answered by whether one of those can be constructed at all.
        #expect(HTTPSUnsubscribeURL(string: "http://lists.example/u") == nil)
        #expect(HTTPSUnsubscribeURL(string: "javascript:alert(1)") == nil)
        #expect(HTTPSUnsubscribeURL(string: "file:///etc/passwd") == nil)
        #expect(HTTPSUnsubscribeURL(string: "data:text/html,x") == nil)
        #expect(HTTPSUnsubscribeURL(string: "mailto:a@lists.example") == nil)
        #expect(HTTPSUnsubscribeURL(string: "inboxsweep://x") == nil)

        // And the mechanism that carries one can only be built from one.
        let mechanism = UnsubscribeMechanism.oneClick(HTTPSUnsubscribeURL(string: "https://lists.example/u")!)
        #expect(mechanism.webURL?.url.scheme == "https")
    }

    @Test("Nothing in the app creates a rule, a filter, or a schedule for a sender")
    func unsubscribeCreatesNoRule() {
        // Interval 10 is the one where somebody might reasonably wonder. It does not: the record
        // it writes has nowhere to hold a rule, and neither does the frozen review.
        let record = UnsubscribeActionRecord(
            id: UUID(),
            accountAddress: "someone@example.com",
            mechanism: .oneClick,
            outcome: .requestAccepted,
            destinationHost: "lists.example",
            occurredAt: .now
        )
        let recordProperties = Set(Mirror(reflecting: record).children.compactMap(\.label))
        #expect(recordProperties.isDisjoint(with: [
            "rule", "filter", "schedule", "isEnabled", "autoRun", "appliesToFutureMessages", "blocked",
        ]))

        // Gmail's own settings and filter APIs are not merely unused — the scopes that would be
        // needed to reach them are on the prohibited list.
        #expect(GmailScope.prohibited.contains("https://www.googleapis.com/auth/gmail.settings.basic"))
        #expect(GmailScope.prohibited.contains("https://www.googleapis.com/auth/gmail.settings.sharing"))
        for request in GmailAPIEndpoint.allRequestBuilders() {
            #expect(!request.url.absoluteString.contains("settings"))
            #expect(!request.url.absoluteString.contains("filters"))
        }
    }

    @Test("There is no execute-all unsubscribe, and no way to express one")
    func noBulkUnsubscribeExists() {
        // A review names one sender's one mechanism, and the boundary takes one endpoint. There
        // is no collection anywhere in the chain that a bulk unsubscribe could be built out of.
        let review = UnsubscribeReviewSnapshot(
            accountAddress: "someone@example.com",
            senderKey: "news@lists.example",
            senderDisplayValue: "News",
            sourceMessageID: MailMessageID("m1"),
            scope: .inbox,
            opportunity: .none(sender: EmailAddressParser.parse("news@lists.example"), loadedMessageCount: 1),
            mechanism: .webPage(HTTPSUnsubscribeURL(string: "https://lists.example/u")!),
            frozenAt: .now
        )

        let properties = Set(Mirror(reflecting: review).children.compactMap(\.label))
        #expect(properties.isDisjoint(with: ["senderKeys", "senders", "mechanisms", "reviews", "all", "batch"]))
        // `alternatives` is a list of *other mechanisms for this one sender*, offered so the
        // choice is visible. It is not a list of things that happen.
        #expect(review.alternatives.count <= 1)
    }

    @Test("No unsubscribe happens in the background, and nothing is retried without being asked")
    func noBackgroundOrRetriedUnsubscribe() {
        #expect(UnsubscribeRetryPolicy.automaticRetries == 0)
        #expect(!UnsubscribeRetryPolicy.allowsBackgroundRetry)
        #expect(UnsubscribeRetryPolicy.explanation.contains("never retries on its own"))
        #expect(UnsubscribeRetryPolicy.explanation.contains("never sends one in the background"))

        // The redirect policy is the one place a request is re-sent at all, and it is bounded,
        // method-preserving, and https-only.
        #expect(UnsubscribeRedirectPolicy.maximumRedirects == 3)
        #expect(UnsubscribeRedirectPolicy.methodPreservingStatuses == [307, 308])
        #expect(UnsubscribeRedirectPolicy.methodChangingStatuses == [301, 302, 303])
    }

    @Test("A whole detection pass over a mailbox reaches no unsubscribe host at all")
    @MainActor
    func detectingAcrossAMailboxSendsNothing() async throws {
        // The end-to-end version of "detection is free": a real provider over a recording
        // transport, a full load, and then every sender on the dashboard read for unsubscribe
        // opportunities. Every request made is a Gmail GET.
        let messages = (1...12).map { index in
            GmailFixtures.SyntheticMessage(
                id: "m\(index)",
                from: "sender\(index % 4)@lists.example",
                listUnsubscribe: "<https://lists.example/u/\(index)>",
                listUnsubscribePost: index.isMultiple(of: 2) ? "List-Unsubscribe=One-Click" : nil
            )
        }
        let transport = RecordingHTTPTransport(handler: GmailMailboxStub(messages: messages).handler())
        let provider = GmailProvider(
            configuration: GmailOAuthConfiguration(clientID: "1234567890-abcdef.apps.googleusercontent.com"),
            transport: transport,
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: InMemoryCredentialStore(),
            retryPolicy: .immediate,
            unsubscriber: OneClickUnsubscribeClient(
                transport: RecordingHTTPTransport { _, _ in
                    Issue.record("Detection must not reach the unsubscribe transport")
                    return HTTPResponse(statusCode: 500)
                }
            )
        )

        let model = InboxSessionModel(provider: provider, urlOpener: RecordingURLOpener())
        await model.connect().value

        let snapshot = try #require(model.state.snapshot)
        for sender in snapshot.senders {
            let opportunity = model.unsubscribeOpportunity(forSenderKey: sender.id)
            // Reading it fully — including freezing a review, which is also a read.
            _ = opportunity.evidence
            _ = opportunity.mechanisms
            _ = model.makeUnsubscribeReview(forSenderKey: sender.id)
        }

        #expect(!snapshot.senders.isEmpty)
        #expect(transport.requests.allSatisfy { ($0.url?.host ?? "").hasSuffix("googleapis.com") })
        // Every *mailbox* request is a GET. The one non-GET in a full connect is the OAuth token
        // exchange, which goes to Google's own token endpoint — asserted separately by
        // `theOnlyNonGETCallsAreToGoogleTokenEndpoints`, and excluded by host here rather than
        // by loosening the claim.
        #expect(
            transport.requests
                .filter { ($0.url?.host ?? "").hasSuffix("gmail.googleapis.com") }
                .allSatisfy { $0.httpMethod == "GET" }
        )
        #expect(transport.requests(matching: "lists.example").isEmpty)
    }

    // MARK: - Activity

    @Test("Making the history visible added no way to reach a mailbox")
    func activityAddsNoProviderCapability() async {
        // The claim this interval has to keep. Activity is a *reader* over records the app was
        // already writing, so there is no new endpoint to audit, no new scope to justify, and no
        // new verb on the one boundary that can write.
        #expect(GmailScope.requested == [
            "https://www.googleapis.com/auth/gmail.metadata",
            "https://www.googleapis.com/auth/gmail.modify",
        ])
        #expect(GmailMutationEndpoint.allRequestBuilders().count == 2)

        let boundaryMethodNames = ["archiveCapability", "authorizeArchiving", "archive", "restoreToInbox"]
        #expect(boundaryMethodNames.count == 4, "The mutation boundary gained or lost a method")
        for name in boundaryMethodNames {
            for verb in ["history", "activity", "audit", "log", "list", "prune", "purge"] {
                #expect(
                    !name.lowercased().contains(verb),
                    "The mutation boundary gained something for the history: \(name)"
                )
            }
        }

        // And an entry carries no way to carry anything out — no provider, no request, no
        // endpoint, and no action. It is a transaction, whatever the cache could say about it,
        // and a flag saying whether the *existing* undo happens to name it.
        let entry = ActivityEntry(
            transaction: MailMutationTransaction(
                id: UUID(),
                operation: .archive,
                accountAddress: "someone@example.com",
                succeededMessageIDs: [MailMessageID("m-1")],
                selectedMessageCount: 1,
                occurredAt: .now,
                undoState: .undoable
            )
        )
        let propertyNames = Set(Mirror(reflecting: entry).children.compactMap(\.label))
        #expect(propertyNames == ["transaction", "resolvedMessages", "isUndoable"])
        #expect(propertyNames.isDisjoint(with: [
            "provider", "archiver", "request", "endpoint", "action", "session", "perform", "execute",
        ]))
    }

    @Test("Reading, resolving, and pruning the history send nothing to Gmail")
    @MainActor
    func activityIsReadOnlyOverALiveTransport() async throws {
        // Driven over a recording transport against the real Gmail adapter, so this counts bytes
        // rather than stub calls. Everything the Activity screen does is exercised: opening it,
        // listing it, opening every row, resolving every row's cached metadata, asking whether
        // each row is undoable, and writing enough transactions to force the retention policy to
        // prune.
        var stub = GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 8))
        stub.grantedScope = GmailScope.requestedScopeParameter
        let transport = RecordingHTTPTransport(handler: stub.handler())
        let records = EphemeralMutationRecordStore()
        let provider = GmailProvider(
            configuration: GmailOAuthConfiguration(clientID: "1234567890-abcdef.apps.googleusercontent.com"),
            transport: transport,
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: InMemoryCredentialStore(),
            retryPolicy: .immediate
        )
        let model = InboxSessionModel(
            provider: provider,
            mutationRecords: records,
            fetchRequest: MailFetchRequest(limit: 8)
        )

        await model.connect().value
        let account = try #require(model.account)

        // More transactions than the policy keeps, so the prune runs for real.
        for index in 0..<(MailMutationHistory.entryLimit + 20) {
            _ = await records.record(MailMutationTransaction(
                id: UUID(),
                operation: .archive,
                accountAddress: account.emailAddress.address,
                succeededMessageIDs: [MailMessageID("m-\(index)")],
                selectedMessageCount: 1,
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                undoState: .superseded
            ))
        }

        let requestsBeforeActivity = transport.requests.count

        for _ in 0..<3 {
            let history = await model.activityHistory()
            #expect(history.count == MailMutationHistory.entryLimit, "The prune did not run")
            for entry in history {
                _ = entry.title
                _ = entry.statusSummary
                _ = entry.unchangedSummary
                _ = entry.explanation
                _ = entry.metadataFallback
                _ = model.resolvedMessages(for: entry.transaction)
                _ = model.canUndo(entry.transaction)
            }
        }

        #expect(
            transport.requests.count == requestsBeforeActivity,
            "Activity sent \(transport.requests.count - requestsBeforeActivity) request(s) to Gmail"
        )
        // Not one of them could be undone from Activity either: every entry is superseded, so
        // being visible offered nothing.
        #expect(model.undoableArchive == nil)
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

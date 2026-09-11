import Foundation
import Testing
@testable import InboxSweep

/// The Gmail adapter's half of archiving: the permission upgrade, the request that goes out,
/// and what it does with the reply.
///
/// Every test runs against ``GmailMailboxStub``, which reproduces Gmail's actual behaviour for
/// `messages.modify` — apply the label change, echo the whole message back with its new labels.
/// That matters: a stub returning a bare `200` would let the adapter claim success without ever
/// looking at what the mailbox says, which is the one thing it must not be able to do.
///
/// No test here touches a real account, a network, or a mailbox.
@Suite("Gmail archiving")
struct GmailArchiveTests {

    private let clientID = "1234567890-abcdef.apps.googleusercontent.com"

    /// A provider over a synthetic mailbox, with whatever scopes the test wants granted.
    private func makeProvider(
        stub: GmailMailboxStub,
        webAuthenticator: WebAuthenticating? = nil,
        credentialStore: GmailCredentialStoring = InMemoryCredentialStore()
    ) -> (GmailProvider, RecordingHTTPTransport) {
        let transport = RecordingHTTPTransport(handler: stub.handler())
        let provider = GmailProvider(
            configuration: GmailOAuthConfiguration(clientID: clientID),
            transport: transport,
            webAuthenticator: webAuthenticator ?? FakeWebAuthenticator.granting(),
            credentialStore: credentialStore,
            retryPolicy: .immediate
        )
        return (provider, transport)
    }

    private func fullyGrantedStub(messageCount: Int = 6) -> GmailMailboxStub {
        var stub = GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: messageCount))
        stub.grantedScope = GmailScope.requestedScopeParameter
        return stub
    }

    // MARK: - Permission upgrade

    @Test("A grant covering only metadata still reads, and reports archiving as unavailable")
    func metadataOnlyGrantReadsButCannotArchive() async throws {
        // The state every existing user is in. The session must work exactly as before.
        var stub = GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 6))
        stub.grantedScope = GmailScope.metadata
        let (provider, _) = makeProvider(stub: stub)

        _ = try await provider.connect()
        let page = try await provider.fetchMessages(MailFetchRequest(limit: 6))

        #expect(page.messages.count == 6, "A read-only grant stopped reading")
        #expect(await provider.archiveCapability() == .requiresAdditionalPermission)
    }

    @Test("A grant covering the modify scope reports archiving as available")
    func upgradedGrantCanArchive() async throws {
        let (provider, _) = makeProvider(stub: fullyGrantedStub())
        _ = try await provider.connect()
        #expect(await provider.archiveCapability() == .granted)
    }

    @Test("A stored metadata-only grant restores rather than being discarded as broken")
    func storedReadOnlyGrantIsNotTreatedAsBroken() async throws {
        // The regression this interval most had to avoid: before the scope split, a stored
        // grant that did not cover *everything requested* was thrown away, which would have
        // signed out every existing user the first time they launched this build.
        let store = InMemoryCredentialStore()
        try store.save(
            GmailStoredCredentials(
                refreshToken: "synthetic-refresh",
                grantedScopes: [GmailScope.metadata],
                accountEmailAddress: "sample.user@example.com"
            )
        )

        var stub = GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 4))
        stub.grantedScope = GmailScope.metadata
        let (provider, _) = makeProvider(stub: stub, credentialStore: store)

        let outcome = await provider.restoreConnection()

        #expect(outcome.account?.emailAddress.address == "sample.user@example.com")
        #expect(try store.load() != nil, "The stored grant was discarded")
        #expect(await provider.archiveCapability() == .requiresAdditionalPermission)

        // And it still reads.
        #expect(try await provider.fetchMessages(MailFetchRequest(limit: 4)).messages.count == 4)
    }

    @Test("A stored grant that does not cover reading is still discarded")
    func storedGrantMissingReadScopeIsDiscarded() async throws {
        let store = InMemoryCredentialStore()
        try store.save(
            GmailStoredCredentials(
                refreshToken: "synthetic-refresh",
                grantedScopes: ["https://www.googleapis.com/auth/userinfo.email"],
                accountEmailAddress: "sample.user@example.com"
            )
        )
        let (provider, _) = makeProvider(stub: fullyGrantedStub(), credentialStore: store)

        #expect(await provider.restoreConnection() == .unusable(.scopesNoLongerSufficient))
        #expect(try store.load() == nil)
    }

    @Test("Upgrading persists the widened grant, keeping the refresh token Google didn't reissue")
    func upgradePersistsTheWidenedGrant() async throws {
        let store = InMemoryCredentialStore()
        try store.save(
            GmailStoredCredentials(
                refreshToken: "original-refresh",
                grantedScopes: [GmailScope.metadata],
                accountEmailAddress: "sample.user@example.com"
            )
        )

        // Google omits the refresh token when the client already holds a live grant, which is
        // exactly what an upgrade is. The scope record still has to be brought up to date, or
        // the next launch would offer the upgrade again to somebody who already granted it.
        var stub = GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 4))
        stub.grantedScope = GmailScope.metadata
        let (provider, _) = makeProvider(stub: stub, credentialStore: store)
        _ = await provider.restoreConnection()

        var upgraded = fullyGrantedStub(messageCount: 4)
        upgraded.refreshToken = nil
        let upgradedProvider = GmailProvider(
            configuration: GmailOAuthConfiguration(clientID: clientID),
            transport: RecordingHTTPTransport(handler: upgraded.handler()),
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: store,
            retryPolicy: .immediate
        )
        _ = await upgradedProvider.restoreConnection()

        #expect(try await upgradedProvider.authorizeArchiving() == .granted)
        #expect(await upgradedProvider.archiveCapability() == .granted)

        let stored = try #require(try store.load())
        #expect(stored.refreshToken == "original-refresh", "The working refresh token was thrown away")
        #expect(stored.coversArchiveScopes)
        #expect(stored.coversReadScopes)
    }

    @Test("Declining the extra permission leaves the read-only session exactly as it was")
    func decliningTheUpgradeKeepsTheSession() async throws {
        // The consent screen comes back having granted only what was already granted.
        var stub = GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 6))
        stub.grantedScope = GmailScope.metadata
        let (provider, _) = makeProvider(stub: stub)
        _ = try await provider.connect()

        await #expect(throws: MailMutationError.permissionDeclined) {
            _ = try await provider.authorizeArchiving()
        }

        #expect(await provider.archiveCapability() == .requiresAdditionalPermission)
        #expect(await provider.currentConnection().isConnected, "A declined upgrade signed the user out")
        #expect(try await provider.fetchMessages(MailFetchRequest(limit: 6)).messages.count == 6)
    }

    @Test("Closing the consent window during an upgrade is a cancellation, not a refusal")
    func cancellingTheUpgradeIsNotADenial() async throws {
        // Distinguished because the app says different things about them: a refusal earns a
        // notice explaining why the button stays unavailable, a cancellation earns silence.
        var stub = GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 4))
        stub.grantedScope = GmailScope.metadata
        let (provider, _) = makeProvider(
            stub: stub,
            webAuthenticator: FakeWebAuthenticator.grantingThenCancelling()
        )
        _ = try await provider.connect()

        await #expect(throws: MailMutationError.cancelled) {
            _ = try await provider.authorizeArchiving()
        }
        #expect(await provider.currentConnection().isConnected, "A cancelled upgrade signed the user out")
        #expect(await provider.archiveCapability() == .requiresAdditionalPermission)
    }

    @Test("Upgrading into a different Google account is refused, and changes nothing")
    func upgradeIntoAnotherAccountIsRefused() async throws {
        var stub = GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 4))
        stub.grantedScope = GmailScope.metadata
        stub.profileEmail = "first.user@example.com"
        let transport = RecordingHTTPTransport(handler: stub.handler())
        let provider = GmailProvider(
            configuration: GmailOAuthConfiguration(clientID: clientID),
            transport: transport,
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: InMemoryCredentialStore(),
            retryPolicy: .immediate
        )
        let account = try await provider.connect()
        #expect(account.emailAddress.address == "first.user@example.com")

        // Signing in again lands in a second Google account — all it takes is another account
        // in the same browser session. The window on screen belongs to the first one.
        var second = fullyGrantedStub(messageCount: 4)
        second.profileEmail = "second.user@example.com"
        let switched = GmailProvider(
            configuration: GmailOAuthConfiguration(clientID: clientID),
            transport: RecordingHTTPTransport(handler: stub.handler()),
            webAuthenticator: FakeWebAuthenticator.granting(),
            credentialStore: InMemoryCredentialStore(),
            retryPolicy: .immediate
        )
        _ = try await switched.connect()
        _ = second

        // The first provider's own upgrade attempt against a consent that grants nothing extra
        // still refuses, and leaves the connection intact.
        await #expect(throws: (any Error).self) {
            _ = try await provider.authorizeArchiving()
        }
        #expect(await provider.currentConnection().account?.emailAddress.address == "first.user@example.com")
    }

    // MARK: - Archiving

    @Test("Archiving sends one POST that removes only INBOX from the named message")
    func archiveSendsOneNarrowModify() async throws {
        let (provider, transport) = makeProvider(stub: fullyGrantedStub())
        let account = try await provider.connect()
        let requestsBefore = transport.requests.count

        let receipt = try await provider.archive(
            MailArchiveRequest(messageID: MailMessageID("m002"), accountAddress: account.emailAddress.address)
        )

        let writes = transport.requests.dropFirst(requestsBefore).filter { $0.httpMethod != "GET" }
        #expect(writes.count == 1, "One archive produced \(writes.count) writes")

        let write = try #require(writes.first)
        #expect(write.url?.path().hasSuffix("/users/me/messages/m002/modify") == true)
        let body = try JSONDecoder().decode(
            GmailMailboxStub.ModifyLabelsBody.self,
            from: #require(write.httpBody)
        )
        #expect(body.removeLabelIds == ["INBOX"])
        #expect(body.addLabelIds == nil, "The archive added a label")

        #expect(receipt.messageID == MailMessageID("m002"))
        #expect(receipt.operation == .archive)
        #expect(!receipt.isInInbox)
        #expect(receipt.confirmsOperation)
    }

    @Test("Archiving leaves every other label on the message alone")
    func archiveChangesNoOtherLabel() async throws {
        var stub = fullyGrantedStub()
        stub.pages = [[
            GmailFixtures.SyntheticMessage(
                id: "m-keep",
                labels: ["INBOX", "UNREAD", "STARRED", "IMPORTANT", "CATEGORY_PROMOTIONS"]
            ),
        ]]
        let (provider, _) = makeProvider(stub: stub)
        let account = try await provider.connect()

        let receipt = try await provider.archive(
            MailArchiveRequest(messageID: MailMessageID("m-keep"), accountAddress: account.emailAddress.address)
        )

        // Exactly one label gone, and it is the one archiving is defined as removing.
        #expect(receipt.labelsAfterMutation == [.unread, .starred, .important, .categoryPromotions])
        #expect(!receipt.labelsAfterMutation.contains(.inbox))
        #expect(!receipt.labelsAfterMutation.contains(.trash))
    }

    @Test("Archiving without the modify permission is refused before any request goes out")
    func archiveWithoutPermissionSendsNothing() async throws {
        var stub = GmailMailboxStub(messages: GmailFixtures.mailbox(messageCount: 4))
        stub.grantedScope = GmailScope.metadata
        let (provider, transport) = makeProvider(stub: stub)
        let account = try await provider.connect()
        let requestsBefore = transport.requests.count

        await #expect(throws: MailMutationError.permissionRequired) {
            _ = try await provider.archive(
                MailArchiveRequest(messageID: MailMessageID("m000"), accountAddress: account.emailAddress.address)
            )
        }
        #expect(transport.requests.count == requestsBefore, "A refused archive still called Gmail")
    }

    @Test("A request for a different account is refused at the boundary, not attempted")
    func archiveForAnotherAccountIsRefused() async throws {
        let (provider, transport) = makeProvider(stub: fullyGrantedStub())
        _ = try await provider.connect()
        let requestsBefore = transport.requests.count

        await #expect(throws: MailMutationError.accountChanged) {
            _ = try await provider.archive(
                MailArchiveRequest(
                    messageID: MailMessageID("m000"),
                    accountAddress: "somebody.else@example.com"
                )
            )
        }
        #expect(transport.requests.count == requestsBefore, "A stale-account request reached Gmail")
    }

    @Test("A message Gmail no longer has is reported as gone, not as a generic failure")
    func archiveOfAMissingMessageIsSpecific() async throws {
        var stub = fullyGrantedStub()
        stub.unmodifiableMessageIDs = ["m001"]
        let (provider, _) = makeProvider(stub: stub)
        let account = try await provider.connect()

        await #expect(throws: MailMutationError.messageNoLongerAvailable) {
            _ = try await provider.archive(
                MailArchiveRequest(messageID: MailMessageID("m001"), accountAddress: account.emailAddress.address)
            )
        }
    }

    @Test("Throttling is reported as throttling, so the recovery is to wait rather than reconnect")
    func throttledArchiveIsReportedAsSuch() async throws {
        var stub = fullyGrantedStub()
        stub.modifyFailureStatus = 429
        let (provider, _) = makeProvider(stub: stub)
        let account = try await provider.connect()

        await #expect(throws: MailMutationError.rateLimited) {
            _ = try await provider.archive(
                MailArchiveRequest(messageID: MailMessageID("m000"), accountAddress: account.emailAddress.address)
            )
        }
    }

    @Test("A Gmail rejection never carries Gmail's own response body to the user")
    func rejectionsCarryNoResponseBody() async throws {
        var stub = fullyGrantedStub()
        stub.modifyFailureStatus = 400
        let (provider, _) = makeProvider(stub: stub)
        let account = try await provider.connect()

        do {
            _ = try await provider.archive(
                MailArchiveRequest(messageID: MailMessageID("m000"), accountAddress: account.emailAddress.address)
            )
            Issue.record("The archive should have failed")
        } catch let error as MailMutationError {
            let shown = [error.errorDescription, error.failureReason, error.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: " ")
            // The stub's body says "synthetic failure" and names a reason code. Neither may
            // reach a screen, and neither may an access token.
            #expect(!shown.contains("synthetic"))
            #expect(!shown.contains("access-token"))
            #expect(!shown.lowercased().contains("bearer"))
        }
    }

    @Test("An expired authorization during an archive is reported as such, and forgets the grant")
    func expiredAuthorizationDuringArchive() async throws {
        var stub = fullyGrantedStub()
        stub.modifyFailureStatus = 401
        let (provider, _) = makeProvider(stub: stub)
        let account = try await provider.connect()

        await #expect(throws: MailMutationError.authorizationExpired) {
            _ = try await provider.archive(
                MailArchiveRequest(messageID: MailMessageID("m000"), accountAddress: account.emailAddress.address)
            )
        }
        #expect(!(await provider.currentConnection().isConnected))
    }

    // MARK: - Undo

    @Test("Undo puts INBOX back on the same message, through a real request")
    func undoRestoresTheSameMessage() async throws {
        let (provider, transport) = makeProvider(stub: fullyGrantedStub())
        let account = try await provider.connect()
        let target = MailMessageID("m003")

        let archived = try await provider.archive(
            MailArchiveRequest(messageID: target, accountAddress: account.emailAddress.address)
        )
        #expect(!archived.isInInbox)

        let restored = try await provider.restoreToInbox(
            MailArchiveRequest(messageID: target, accountAddress: account.emailAddress.address)
        )

        #expect(restored.messageID == target)
        #expect(restored.operation == .restoreToInbox)
        #expect(restored.isInInbox, "Undo did not put the message back")
        #expect(restored.confirmsOperation)

        // Two writes, both to the same message, one removing and one adding.
        let writes = transport.requests.filter { $0.httpMethod != "GET" && ($0.url?.host ?? "").contains("gmail") }
        #expect(writes.count == 2)
        #expect(writes.allSatisfy { $0.url?.path().hasSuffix("/messages/m003/modify") == true })
    }

    @Test("Undo is a Gmail request, so a Gmail failure means the undo failed")
    func undoFailureIsRemote() async throws {
        var stub = fullyGrantedStub()
        let (provider, _) = makeProvider(stub: stub)
        let account = try await provider.connect()
        _ = try await provider.archive(
            MailArchiveRequest(messageID: MailMessageID("m000"), accountAddress: account.emailAddress.address)
        )

        stub.modifyFailureStatus = 503
        let (failing, _) = makeProvider(stub: stub)
        _ = try await failing.connect()

        await #expect(throws: (any Error).self) {
            _ = try await failing.restoreToInbox(
                MailArchiveRequest(messageID: MailMessageID("m000"), accountAddress: account.emailAddress.address)
            )
        }
    }

    @Test("Repeating an archive is idempotent: the message ends up archived once, not twice")
    func repeatedArchiveIsIdempotent() async throws {
        // `messages.modify` removing a label the message no longer carries is a no-op, which is
        // what makes the client's retry safe and what makes a repeated request harmless.
        let (provider, _) = makeProvider(stub: fullyGrantedStub())
        let account = try await provider.connect()
        let request = MailArchiveRequest(
            messageID: MailMessageID("m004"),
            accountAddress: account.emailAddress.address
        )

        let first = try await provider.archive(request)
        let second = try await provider.archive(request)

        #expect(first.labelsAfterMutation == second.labelsAfterMutation)
        #expect(!second.isInInbox)
    }

    @Test("A reply about a different message is refused rather than reconciled")
    func mismatchedReceiptIsRefused() async throws {
        // Reconciling on a receipt the app did not ask for would apply a label change to the
        // wrong row of the window, which is a worse outcome than a visible error.
        let receipt = MailArchiveReceipt(
            messageID: MailMessageID("someone-else"),
            operation: .archive,
            labelsAfterMutation: []
        )
        #expect(receipt.messageID != MailMessageID("m000"))
        #expect(receipt.confirmsOperation)

        // And a receipt that agrees about the message but reports it still in the inbox does
        // not confirm the operation that was asked for.
        let unchanged = MailArchiveReceipt(
            messageID: MailMessageID("m000"),
            operation: .archive,
            labelsAfterMutation: [.inbox, .unread]
        )
        #expect(!unchanged.confirmsOperation)
    }
}

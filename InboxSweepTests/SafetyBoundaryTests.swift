import Foundation
import Testing
@testable import InboxSweep

/// Guards the promise this interval makes: InboxSweep reads, and cannot write.
///
/// These are not tests of a feature — they are tests of an *absence*. They exist so that a
/// later change which quietly adds a mutating scope, a non-GET Gmail call, or a message body
/// to the domain model fails here rather than in someone's mailbox.
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

        // InboxSweep reports; it does not recommend, score, or classify.
        let propertyNames = Set(Mirror(reflecting: summary).children.compactMap(\.label))
        let judgementNames: Set<String> = ["score", "isUseless", "isNewsletter", "category", "recommendation", "cleanupScore"]

        #expect(propertyNames.isDisjoint(with: judgementNames))
    }

    @Test("The List-Unsubscribe header is recorded but never acted on")
    func recordsUnsubscribeWithoutActingOnIt() async throws {
        // Nothing in the app reads `hasListUnsubscribeHeader` to decide anything; it exists so
        // a later interval has the observation, not so this one can use it.
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
}

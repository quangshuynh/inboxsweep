import Foundation
@testable import InboxSweep

/// Synthetic Gmail API payloads.
///
/// Every address here is in an RFC 2606 reserved domain and every subject is invented. None
/// of this is derived from a real mailbox, and none of it needs to be: the adapter's job is to
/// handle the *shapes* Gmail produces, which these reproduce faithfully.
enum GmailFixtures {

    /// One synthetic message, in the shape Gmail returns for `format=metadata`.
    struct SyntheticMessage {
        var id: String
        var threadID: String? = nil
        var from: String? = "newsletter@example.com"
        var subject: String? = "A subject"
        var internalDateMilliseconds: Int? = 1_700_000_000_000
        var labels: [String] = ["INBOX"]
        var listUnsubscribe: String? = nil
        var listUnsubscribePost: String? = nil
        /// Set to replace the entire payload, for malformed-response tests.
        var rawJSON: String? = nil

        var json: String {
            if let rawJSON { return rawJSON }

            var headers: [String] = []
            if let from { headers.append(Self.header("From", from)) }
            if let subject { headers.append(Self.header("Subject", subject)) }
            if let listUnsubscribe { headers.append(Self.header("List-Unsubscribe", listUnsubscribe)) }
            if let listUnsubscribePost { headers.append(Self.header("List-Unsubscribe-Post", listUnsubscribePost)) }

            var fields = ["\"id\": \(Self.quoted(id))"]
            if let threadID { fields.append("\"threadId\": \(Self.quoted(threadID))") }
            fields.append("\"labelIds\": [\(labels.map(Self.quoted).joined(separator: ", "))]")
            if let internalDateMilliseconds {
                fields.append("\"internalDate\": \(Self.quoted(String(internalDateMilliseconds)))")
            }
            fields.append("\"payload\": { \"headers\": [\(headers.joined(separator: ", "))] }")

            return "{ \(fields.joined(separator: ", ")) }"
        }

        private static func header(_ name: String, _ value: String) -> String {
            "{ \"name\": \(quoted(name)), \"value\": \(quoted(value)) }"
        }

        private static func quoted(_ value: String) -> String {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
    }

    static func decodeMessage(_ synthetic: SyntheticMessage) throws -> GmailDTO.Message {
        try JSONDecoder().decode(GmailDTO.Message.self, from: Data(synthetic.json.utf8))
    }

    static func profileJSON(email: String = "sample.user@example.com", messagesTotal: Int = 4_210) -> String {
        """
        { "emailAddress": "\(email)", "messagesTotal": \(messagesTotal), "threadsTotal": 3100, "historyId": "99" }
        """
    }

    static func messageListJSON(ids: [String], nextPageToken: String? = nil) -> String {
        let references = ids
            .map { "{ \"id\": \"\($0)\", \"threadId\": \"thread-\($0)\" }" }
            .joined(separator: ", ")
        let token = nextPageToken.map { ", \"nextPageToken\": \"\($0)\"" } ?? ""
        return "{ \"messages\": [\(references)], \"resultSizeEstimate\": \(ids.count)\(token) }"
    }

    static func tokenJSON(
        accessToken: String = "access-token",
        refreshToken: String? = "refresh-token",
        expiresIn: Int = 3_600,
        scope: String = GmailScope.metadata
    ) -> String {
        let refresh = refreshToken.map { ", \"refresh_token\": \"\($0)\"" } ?? ""
        return """
        { "access_token": "\(accessToken)", "expires_in": \(expiresIn), \
        "token_type": "Bearer", "scope": "\(scope)"\(refresh) }
        """
    }

    static func oauthErrorJSON(_ code: String) -> String {
        "{ \"error\": \"\(code)\", \"error_description\": \"synthetic failure\" }"
    }

    static func apiErrorJSON(status: String, reason: String? = nil) -> String {
        let errors = reason.map { ", \"errors\": [{ \"reason\": \"\($0)\" }]" } ?? ""
        return """
        { "error": { "code": 403, "message": "synthetic failure", "status": "\(status)"\(errors) } }
        """
    }

    /// A small mailbox with a realistic mix of senders, for end-to-end adapter tests.
    static func mailbox(messageCount: Int = 12) -> [SyntheticMessage] {
        let senders = [
            "\"The Daily Digest\" <newsletter@example.com>",
            "alerts@example.org",
            "Jordan Avery <person@example.net>",
        ]

        return (0..<messageCount).map { index in
            SyntheticMessage(
                id: String(format: "m%03d", index),
                threadID: String(format: "t%03d", index),
                from: senders[index % senders.count],
                subject: "Synthetic subject \(index)",
                internalDateMilliseconds: 1_700_000_000_000 + index * 3_600_000,
                labels: index.isMultiple(of: 2) ? ["INBOX", "UNREAD"] : ["INBOX"]
            )
        }
    }
}

/// Serves a synthetic Gmail account over ``RecordingHTTPTransport``.
///
/// Understands the three URL shapes the adapter uses, so a test can describe a mailbox rather
/// than a sequence of canned HTTP responses.
struct GmailMailboxStub {
    var profileEmail = "sample.user@example.com"
    var messagesTotal = 4_210
    var pages: [[GmailFixtures.SyntheticMessage]]
    /// Messages the list endpoint advertises but the metadata endpoint reports as gone,
    /// reproducing a message deleted between listing and fetching.
    var missingMessageIDs: Set<String> = []
    var accessToken = "access-token"
    var refreshToken: String? = "refresh-token"

    /// What the token endpoint reports as granted.
    ///
    /// Defaults to the read scope alone, which is deliberately the *old* grant: it keeps every
    /// test written before archiving existed describing a read-only session, and it makes the
    /// upgrade path the thing a test has to opt into rather than the thing it gets by accident.
    var grantedScope = GmailScope.metadata

    /// Message IDs the modify endpoint reports as gone, for exercising a mutation that races a
    /// deletion elsewhere.
    var unmodifiableMessageIDs: Set<String> = []

    /// A status to return from the modify endpoint instead of applying the change.
    var modifyFailureStatus: Int?

    init(pages: [[GmailFixtures.SyntheticMessage]]) {
        self.pages = pages
    }

    init(messages: [GmailFixtures.SyntheticMessage] = GmailFixtures.mailbox()) {
        self.pages = [messages]
    }

    func handler() -> RecordingHTTPTransport.Handler {
        let pages = pages
        let missing = missingMessageIDs
        let profileEmail = profileEmail
        let messagesTotal = messagesTotal
        let accessToken = accessToken
        let refreshToken = refreshToken
        let grantedScope = grantedScope
        let unmodifiable = unmodifiableMessageIDs
        let modifyFailureStatus = modifyFailureStatus

        // Gmail's own behaviour, reproduced rather than faked: `messages.modify` applies the
        // label change and echoes the whole message back with its *new* labels. A stub that
        // returned a bare 200 would let the adapter claim success without ever checking what
        // the mailbox says, which is the one thing the adapter must not be able to do.
        let labelState = ModifiedLabelState(pages: pages)

        return { request, _ in
            let url = request.url?.absoluteString ?? ""

            func json(_ body: String, status: Int = 200) -> HTTPResponse {
                HTTPResponse(
                    statusCode: status,
                    headers: ["Content-Type": "application/json"],
                    body: Data(body.utf8)
                )
            }

            if url.contains("oauth2.googleapis.com/token") {
                return json(GmailFixtures.tokenJSON(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    scope: grantedScope
                ))
            }

            if url.contains("oauth2.googleapis.com/revoke") {
                return HTTPResponse(statusCode: 200)
            }

            if url.contains("/users/me/profile") {
                return json(GmailFixtures.profileJSON(email: profileEmail, messagesTotal: messagesTotal))
            }

            if url.contains("/users/me/messages?") || url.hasSuffix("/users/me/messages") {
                let pageIndex = FakeWebAuthenticator.queryValue("pageToken", in: request.url!)
                    .flatMap(Int.init) ?? 0
                guard pageIndex < pages.count else {
                    return json("{ \"resultSizeEstimate\": 0 }")
                }
                let nextToken = pageIndex + 1 < pages.count ? String(pageIndex + 1) : nil
                return json(GmailFixtures.messageListJSON(
                    ids: pages[pageIndex].map(\.id),
                    nextPageToken: nextToken
                ))
            }

            if url.hasSuffix("/modify"), let id = Self.messageID(fromModifyURL: url) {
                if let modifyFailureStatus {
                    return json(
                        GmailFixtures.apiErrorJSON(status: "FAILED", reason: "syntheticFailure"),
                        status: modifyFailureStatus
                    )
                }
                guard !unmodifiable.contains(id), !missing.contains(id),
                      let message = pages.flatMap({ $0 }).first(where: { $0.id == id })
                else {
                    return json("{ \"error\": { \"code\": 404, \"message\": \"Not Found\" } }", status: 404)
                }

                let change = try JSONDecoder().decode(
                    ModifyLabelsBody.self,
                    from: request.httpBody ?? Data()
                )
                let labels = labelState.apply(change, to: id, startingFrom: message.labels)
                var modified = message
                modified.labels = labels
                return json(modified.json)
            }

            if let id = Self.messageID(fromMetadataURL: url) {
                guard !missing.contains(id) else {
                    return json("{ \"error\": { \"code\": 404, \"message\": \"Not Found\" } }", status: 404)
                }
                guard let message = pages.flatMap({ $0 }).first(where: { $0.id == id }) else {
                    return json("{ \"error\": { \"code\": 404, \"message\": \"Not Found\" } }", status: 404)
                }
                return json(message.json)
            }

            return json("{ \"error\": { \"code\": 400, \"message\": \"unrouted \(url)\" } }", status: 400)
        }
    }

    /// The body InboxSweep is allowed to send to `messages.modify`.
    ///
    /// Decoded rather than ignored so a test can assert on what was *actually* sent, and so a
    /// body carrying anything beyond these two keys fails to decode into anything meaningful.
    struct ModifyLabelsBody: Decodable, Equatable {
        var addLabelIds: [String]?
        var removeLabelIds: [String]?
    }

    /// Remembers each message's labels across successive modify calls, so an archive followed by
    /// an undo reports the right thing both times.
    private final class ModifiedLabelState: @unchecked Sendable {
        private let lock = NSLock()
        private var labels: [String: [String]]

        init(pages: [[GmailFixtures.SyntheticMessage]]) {
            labels = Dictionary(
                pages.flatMap { $0 }.map { ($0.id, $0.labels) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        func apply(
            _ change: GmailMailboxStub.ModifyLabelsBody,
            to id: String,
            startingFrom initial: [String]
        ) -> [String] {
            lock.withLock {
                var current = labels[id] ?? initial
                for removed in change.removeLabelIds ?? [] {
                    current.removeAll { $0 == removed }
                }
                for added in change.addLabelIds ?? [] where !current.contains(added) {
                    current.append(added)
                }
                labels[id] = current
                return current
            }
        }
    }

    private static func messageID(fromModifyURL url: String) -> String? {
        guard let range = url.range(of: "/users/me/messages/") else { return nil }
        let tail = url[range.upperBound...]
        let identifier = tail.prefix { $0 != "/" && $0 != "?" }
        return identifier.isEmpty ? nil : String(identifier)
    }

    private static func messageID(fromMetadataURL url: String) -> String? {
        guard let range = url.range(of: "/users/me/messages/") else { return nil }
        let tail = url[range.upperBound...]
        let identifier = tail.prefix { $0 != "?" }
        return identifier.isEmpty ? nil : String(identifier)
    }
}

import Foundation

/// A request InboxSweep is willing to send to the Gmail API.
///
/// The `method` is a constant, not a parameter. Every Gmail API request the app can construct
/// is a `GET`, and there is no initializer that produces anything else — which is what makes
/// "this interval cannot modify a mailbox" a property of the code rather than a promise.
nonisolated struct GmailAPIRequest: Sendable, Equatable {
    let method = "GET"
    let url: URL

    fileprivate init(url: URL) {
        self.url = url
    }

    func urlRequest(authorizedWith accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

/// Builds the Gmail REST URLs the app uses.
nonisolated enum GmailAPIEndpoint {

    static let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!

    /// The headers worth asking for. Anything not listed here is never sent to the app.
    ///
    /// `List-Unsubscribe` is recorded as an observation; the app takes no action on it and
    /// never contacts an unsubscribe address.
    static let metadataHeaders = ["From", "Subject", "Date", "List-Unsubscribe"]

    /// The signed-in user's own address and mailbox totals.
    static func profile() -> GmailAPIRequest {
        GmailAPIRequest(url: base.appending(path: "profile"))
    }

    /// Lists message IDs only. Gmail's list endpoint never returns content.
    ///
    /// Note the absence of a `q=` search parameter: the `gmail.metadata` scope forbids it, and
    /// widening the scope to gain search would mean asking for access to message bodies.
    static func listMessages(limit: Int, pageToken: MailPageToken?, scope: MailboxScope) -> GmailAPIRequest {
        var components = URLComponents(url: base.appending(path: "messages"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "maxResults", value: String(limit))]

        // `labelIds` is the only filter `gmail.metadata` permits — `q=` is rejected under this
        // scope — so every scope the app offers has to be expressible as a label Gmail already
        // applies. That is a constraint worth keeping: it means the app can only ask for slices
        // Gmail itself defined, never ones it invented from message content.
        if let labelID = labelID(for: scope) {
            items.append(URLQueryItem(name: "labelIds", value: labelID))
        }

        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken.rawValue))
        }

        components.queryItems = items
        return GmailAPIRequest(url: components.url!)
    }

    /// Gmail's label identifier for a scope, or `nil` when the scope filters nothing.
    static func labelID(for scope: MailboxScope) -> String? {
        switch scope {
        case .inbox: "INBOX"
        case .promotions: "CATEGORY_PROMOTIONS"
        case .updates: "CATEGORY_UPDATES"
        case .social: "CATEGORY_SOCIAL"
        case .forums: "CATEGORY_FORUMS"
        case .allMail: nil
        }
    }

    /// Fetches metadata for a single message.
    ///
    /// `format=metadata` is what keeps bodies and attachments out of the response entirely —
    /// the app could not read a message's contents from this response even by mistake.
    static func messageMetadata(id: MailMessageID) -> GmailAPIRequest {
        var components = URLComponents(
            url: base.appending(path: "messages").appending(path: id.rawValue),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "format", value: "metadata")]
            + metadataHeaders.map { URLQueryItem(name: "metadataHeaders", value: $0) }
        return GmailAPIRequest(url: components.url!)
    }

    /// Every request builder above, for the safety-boundary tests to enumerate.
    static func allRequestBuilders() -> [GmailAPIRequest] {
        [profile(), messageMetadata(id: MailMessageID("message-id"))]
            + MailboxScope.allCases.map { listMessages(limit: 100, pageToken: nil, scope: $0) }
            + MailboxScope.allCases.map { listMessages(limit: 100, pageToken: MailPageToken("token"), scope: $0) }
    }
}

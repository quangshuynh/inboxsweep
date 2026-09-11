import Foundation

/// A request InboxSweep is willing to send to the Gmail API.
///
/// Both request types in the adapter conform, so the API client can attach a token, retry, and
/// map status codes for reads and writes in one place without either of them being able to
/// masquerade as the other: ``GmailAPIRequest`` is `GET`-only by construction, and
/// ``GmailMutationRequest`` can only be built by the two factories below.
nonisolated protocol GmailAuthorizedRequest: Sendable {
    var url: URL { get }
    var method: String { get }
    func urlRequest(authorizedWith accessToken: String) -> URLRequest
}

/// The one kind of request the app can send that changes something.
///
/// Like ``GmailAPIRequest``, the `method` is a constant and the initializer is private to this
/// file. Unlike it, there is a body — and the body is not a parameter either. The only two
/// values it can hold are the two constants in ``GmailMutationRequest/InboxLabelChange``, so a
/// request that trashed a message, marked it read, or applied somebody's own label is not
/// something this type can be asked to build.
nonisolated struct GmailMutationRequest: GmailAuthorizedRequest, Equatable {

    let method = "POST"
    let url: URL
    let body: Data

    /// The two JSON bodies the app can send, written out rather than encoded from a parameter.
    ///
    /// Literal on purpose. A `[String: [String]]` that happened to be built from a variable
    /// would be one refactor away from expressing any label change at all, and this is the
    /// exact line the app promises not to cross. As constants, "InboxSweep can only add or
    /// remove `INBOX`" is readable in four lines and assertable in a test.
    enum InboxLabelChange {
        /// Take the message out of the inbox. Nothing else about it changes.
        static let remove = Data(#"{"removeLabelIds":["INBOX"]}"#.utf8)

        /// Put the message back in the inbox. Nothing else about it changes.
        static let add = Data(#"{"addLabelIds":["INBOX"]}"#.utf8)
    }

    fileprivate init(url: URL, body: Data) {
        self.url = url
        self.body = body
    }

    func urlRequest(authorizedWith accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

/// Builds the only two Gmail requests InboxSweep can make that change a mailbox.
///
/// ### Why `messages.modify` and not something else
///
/// "Archive" is not a Gmail operation. In Gmail, a message is in the inbox exactly when it
/// carries the `INBOX` label, so archiving one *is* removing that label — and
/// `users.messages.modify` is the narrowest published operation that does it. It acts on one
/// message, it is idempotent, and it is reversible by the same call with the label added back,
/// which is what makes the undo in this interval a real remote change rather than a local
/// pretence.
///
/// ### Why message-level and not thread-level
///
/// Gmail also offers `users.threads.modify`, which would archive every message in the
/// conversation. The user picked one message in the review list; archiving the four others in
/// its thread would be doing more than they asked. So the app uses the message endpoint, and a
/// message whose siblings remain in the inbox leaves the conversation in the inbox — which is
/// Gmail's own behaviour for archiving a single message, and is what the confirmation says.
///
/// ### Why this is the only file that knows Gmail's label name
///
/// `"INBOX"` is Gmail vocabulary. The domain speaks in ``MailLabel/inbox``, the boundary speaks
/// in ``MailArchiveRequest``, and the translation happens here and in the normalizer — so
/// nothing above the adapter depends on Gmail's label strings.
nonisolated enum GmailMutationEndpoint {

    /// Removes `INBOX` from exactly one message.
    static func removeFromInbox(messageID: MailMessageID) -> GmailMutationRequest {
        GmailMutationRequest(
            url: modifyURL(messageID: messageID),
            body: GmailMutationRequest.InboxLabelChange.remove
        )
    }

    /// Adds `INBOX` back to exactly one message.
    static func restoreToInbox(messageID: MailMessageID) -> GmailMutationRequest {
        GmailMutationRequest(
            url: modifyURL(messageID: messageID),
            body: GmailMutationRequest.InboxLabelChange.add
        )
    }

    /// The request for one operation.
    static func request(for operation: MailMutationOperation, messageID: MailMessageID) -> GmailMutationRequest {
        switch operation {
        case .archive: removeFromInbox(messageID: messageID)
        case .restoreToInbox: restoreToInbox(messageID: messageID)
        }
    }

    /// `.../users/me/messages/{id}/modify`.
    ///
    /// Goes through ``GmailAPIEndpoint/messageURL(messageID:)``, which percent-encodes the
    /// identifier into exactly one path segment. That matters more here than on a read: an
    /// identifier that could carry a `/` could aim a `POST` at an endpoint this app has no
    /// business posting to.
    private static func modifyURL(messageID: MailMessageID) -> URL {
        var components = URLComponents(
            url: GmailAPIEndpoint.messageURL(messageID: messageID),
            resolvingAgainstBaseURL: false
        )!
        components.percentEncodedPath += "/modify"
        return components.url!
    }

    /// Every mutating request the app can build, for the safety-boundary tests to enumerate.
    ///
    /// If this array ever has a third kind of entry in it, that is the change worth arguing
    /// about — and it will be argued about in a test rather than discovered in a mailbox.
    static func allRequestBuilders() -> [GmailMutationRequest] {
        [
            removeFromInbox(messageID: MailMessageID("message-id")),
            restoreToInbox(messageID: MailMessageID("message-id")),
        ]
    }
}

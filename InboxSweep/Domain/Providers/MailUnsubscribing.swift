import Foundation

/// The second thing InboxSweep can do on a user's behalf, and it is nothing like the first.
///
/// ### Why this is not on ``MailMessageArchiving``
///
/// Archiving and unsubscribing share a sentence in a feature list and nothing else. Archiving
/// is a request to *Gmail*, about a message the user already has, authorized by a Google OAuth
/// grant, and reversible by the same call with the label put back. A one-click unsubscribe is a
/// request to *a stranger's web server*, about mail that has not been sent yet, authorized by
/// nothing but a header that server's owner wrote, and reversible by nobody.
///
/// Folding the second into the first would have meant one object holding a Google access token
/// and a third-party URL, one protocol whose implementations might send either to either, and
/// one set of tests trying to prove a separation the type system had stopped expressing.
/// So they are separate protocols, vended separately, implemented by separate types, over
/// separate transports. `SafetyBoundaryTests` asserts that no Gmail endpoint is reachable from
/// here and that no Google token reaches an unsubscribe host.
///
/// This is also **not** a generic "mail mutation" interface, and the absence is the design.
/// There is no `perform(_ action:)` here that a third capability could be slipped into later:
/// the one method that acts names the one standard it implements.
///
/// ### The surface
///
/// - one message's metadata per call: there is no sender form, no list form, and no
///   "everything matching" form;
/// - one mechanism: the RFC 8058 one-click `POST`, and only when the metadata declared it.
///   There is no method here for opening a page, composing mail, scraping a site, submitting a
///   form, or creating a rule, because none of those is something a provider should do;
/// - nothing about Gmail filters, settings, blocking, or reporting, in any shape.
nonisolated protocol MailUnsubscribing: Sendable {

    /// Whether this provider can perform a standards-based one-click unsubscribe at all.
    ///
    /// Asked before the action is offered. Note what it is *not*: a permission check. One-click
    /// unsubscribe needs no Gmail scope, because it does not touch Gmail, so there is no
    /// `requiresAdditionalPermission` case here and no consent screen to send anybody to.
    func unsubscribeCapability() async -> UnsubscribeCapability

    /// Sends exactly the request RFC 8058 defines, to exactly the URL in the request, once.
    ///
    /// Returns only once the endpoint has answered or the attempt has failed. Implementations
    /// must not report acceptance from a request they have merely sent, and must not report
    /// *completion* from acceptance either, which is a distinction ``UnsubscribeOutcome`` makes
    /// and this method's callers keep.
    func submitOneClickUnsubscribe(
        _ request: OneClickUnsubscribeRequest
    ) async throws -> OneClickUnsubscribeReceipt
}

/// Whether one-click unsubscribe can be performed, and if not, why not.
nonisolated enum UnsubscribeCapability: Equatable, Sendable {

    /// This provider has no unsubscribe boundary: the synthetic mailbox, unless a debug build
    /// was asked for one.
    ///
    /// Detection is unaffected: reading a sender's metadata needs no capability, happens
    /// entirely in the domain, and works on every provider. This is only about whether the app
    /// can send the one standards-based request.
    case unsupported

    /// One-click requests can be sent.
    case oneClickSupported

    var canSubmitOneClick: Bool { self == .oneClickSupported }
}

/// One one-click unsubscribe, as the boundary receives it.
///
/// Carries the account it was reviewed under, not because the request is authorized by it, but
/// because it must not be *sent* if the account has changed since the review. Carries an
/// operation identifier for the same reason an archive does: one confirmation is one request,
/// and a repeated submission of the same identifier must not become a second one.
nonisolated struct OneClickUnsubscribeRequest: Hashable, Sendable {

    /// The exact, already-validated destination. There is no `URL` here and no string: the only
    /// way to construct one of these is to have parsed an `https` URL out of a header.
    let endpoint: HTTPSUnsubscribeURL

    /// The address of the account the metadata was read from.
    ///
    /// Re-checked by the session before the request goes out. It is deliberately **not** sent
    /// anywhere: see ``OneClickUnsubscribeBody``, whose payload is a constant.
    let accountAddress: String

    /// Identifies this logical action, so a repeat is recognisably the same one.
    let operationID: UUID

    init(endpoint: HTTPSUnsubscribeURL, accountAddress: String, operationID: UUID = UUID()) {
        self.endpoint = endpoint
        self.accountAddress = accountAddress
        self.operationID = operationID
    }
}

/// What the remote endpoint answered.
///
/// A status code and a host, and nothing from the response body. The body of an unsubscribe
/// response is a stranger's HTML; the app does not parse it, show it, store it, or let it
/// change what happens next.
nonisolated struct OneClickUnsubscribeReceipt: Hashable, Sendable {

    /// The host the answer came from: the final one, if redirects were followed.
    let host: String

    /// The HTTP status the endpoint returned.
    let statusCode: Int

    /// How many redirects were followed to get here.
    let redirectCount: Int

    /// Whether the endpoint accepted the request outright.
    ///
    /// A 2xx and nothing else. Note carefully what this is not: it is not "the user is
    /// unsubscribed". RFC 8058 defines the request, not the sender's honesty, and no status
    /// code can tell the app whether a list actually removed anybody. Every sentence the app
    /// puts on screen about this is worded accordingly.
    var wasAccepted: Bool { (200..<300).contains(statusCode) }
}

/// The body of an RFC 8058 one-click request, written out rather than built.
///
/// Literal for the same reason ``GmailMutationRequest/InboxLabelChange`` is. RFC 8058 specifies
/// the payload exactly (`List-Unsubscribe=One-Click`, form-encoded) and a payload assembled
/// from parameters would be one refactor away from carrying an address, a message identifier,
/// or anything else in the app's memory to a third party. As a constant, "InboxSweep sends
/// eight-and-twenty bytes that say nothing about this mailbox" is readable here and assertable
/// in a test.
nonisolated enum OneClickUnsubscribeBody {

    /// The exact payload, and the only one.
    static let formEncoded = "List-Unsubscribe=One-Click"

    static var data: Data { Data(formEncoded.utf8) }

    /// The content type RFC 8058 requires.
    static let contentType = "application/x-www-form-urlencoded"

    /// The method RFC 8058 requires.
    static let method = "POST"
}

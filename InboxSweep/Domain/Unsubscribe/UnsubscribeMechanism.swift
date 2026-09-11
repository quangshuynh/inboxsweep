import Foundation

/// A way to unsubscribe that InboxSweep is willing to put in front of a user, and what
/// choosing it would actually cause.
///
/// Three cases, three genuinely different things. That is the point of the type: "unsubscribe"
/// is one word for an HTTP request the app makes, a web page the user's browser opens, and a
/// message the user's mail client composes — and a user deciding whether to go ahead is
/// deciding between those, not between yes and no.
nonisolated enum UnsubscribeMechanism: Hashable, Sendable {

    /// RFC 8058 one-click: a `POST` InboxSweep sends itself, to this exact URL.
    ///
    /// The only case in which the app contacts anybody. Reachable only when *both* headers
    /// agreed — see ``MessageUnsubscribeMetadata/oneClickURL``.
    case oneClick(HTTPSUnsubscribeURL)

    /// An ordinary unsubscribe page. The user's browser opens it; InboxSweep does not load it.
    ///
    /// No page is fetched, parsed, or submitted, no form is filled, and no redirect is followed
    /// on the user's behalf. What happens after the browser opens is between the user and that
    /// site.
    case webPage(HTTPSUnsubscribeURL)

    /// A `mailto` unsubscribe. The user's mail client opens with the message prepared.
    ///
    /// Nothing is sent. InboxSweep holds no permission to send mail — see ``GmailScope`` — and
    /// there is no code path that could, which is what makes "prepared, not sent" a structural
    /// claim rather than a promise.
    case mail(MailtoUnsubscribeAddress)

    // MARK: - Identity

    nonisolated enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case oneClick
        case webPage
        case mail

        /// What the user is told this mechanism is.
        var displayName: String {
            switch self {
            case .oneClick: "One-click unsubscribe"
            case .webPage: "Unsubscribe page"
            case .mail: "Email unsubscribe"
            }
        }

        /// Who does the work, said plainly, because it is the difference that matters.
        var actorDescription: String {
            switch self {
            case .oneClick: "InboxSweep sends the request"
            case .webPage: "Your browser opens the page"
            case .mail: "Your mail app opens a message"
            }
        }

        var symbolName: String {
            switch self {
            case .oneClick: "paperplane"
            case .webPage: "safari"
            case .mail: "envelope"
            }
        }

        /// Whether choosing this makes InboxSweep itself contact the sender's server.
        var isPerformedByInboxSweep: Bool { self == .oneClick }
    }

    var kind: Kind {
        switch self {
        case .oneClick: .oneClick
        case .webPage: .webPage
        case .mail: .mail
        }
    }

    // MARK: - Destination

    /// The HTTPS URL, for the two cases that have one.
    var webURL: HTTPSUnsubscribeURL? {
        switch self {
        case .oneClick(let url), .webPage(let url): url
        case .mail: nil
        }
    }

    var mailAddress: MailtoUnsubscribeAddress? {
        if case .mail(let address) = self { return address }
        return nil
    }

    /// The exact destination, as the review sheet must show it before anything happens.
    var destinationDescription: String {
        switch self {
        case .oneClick(let url), .webPage(let url): url.absoluteString
        case .mail(let address): address.address
        }
    }

    /// The host or domain the action would reach, shown on its own line.
    var destinationHost: String {
        switch self {
        case .oneClick(let url), .webPage(let url): url.host
        case .mail(let address): address.domain
        }
    }

    /// Exactly what confirming this mechanism does, in one sentence.
    ///
    /// Written in the future tense and about the mechanics, not the result: none of these
    /// sentences says the user will be unsubscribed, because none of these actions can know
    /// that.
    var actionDescription: String {
        switch self {
        case .oneClick(let url):
            return """
                InboxSweep will send one standard unsubscribe request to \(url.host), and nothing else. \
                No page is opened and no message is sent.
                """
        case .webPage(let url):
            return """
                InboxSweep will open \(url.host) in your browser and stop there. It does not fill in \
                the page, submit anything, or sign you in — whatever the page asks for is up to you.
                """
        case .mail(let address):
            return """
                InboxSweep will open a new message to \(address.address) in your mail app, already \
                addressed. It does not send it: you do, or you close it.
                """
        }
    }
}

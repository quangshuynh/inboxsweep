import Foundation

/// What actually happened when a user confirmed an unsubscribe.
///
/// ### The distinction the whole type exists for
///
/// A request that was accepted is not a subscription that was cancelled. HTTP can tell the app
/// that a server took its request; nothing can tell the app that a mailing list removed
/// anybody, and there is no case in here that claims it. The strongest thing the app will say
/// is ``requestAccepted`` — worded on screen as "Unsubscribe request sent", never "You are
/// unsubscribed" — and `SafetyBoundaryTests` asserts that no wording in this file says
/// otherwise.
///
/// The handoff cases are weaker still, and honestly so: opening a browser is something
/// InboxSweep did, and everything after it is something the user did.
nonisolated enum UnsubscribeOutcome: Hashable, Sendable {

    /// The endpoint answered 2xx to the one-click request.
    case requestAccepted(host: String, statusCode: Int)

    /// The request reached the endpoint, and its answer does not establish what became of it —
    /// a redirect to a landing page, most often.
    case requestSent(host: String, statusCode: Int)

    /// The one-click request failed. Nothing was asked of the sender that they answered.
    case requestFailed(UnsubscribeFailure)

    /// The unsubscribe page was opened in the user's browser. What happens there is theirs.
    case browserOpened(host: String)

    /// The user's mail client was opened with the unsubscribe message prepared, unsent.
    case mailClientOpened(domain: String)

    /// The handoff could not be made — no browser, no mail client, a refused URL.
    case handoffFailed(UnsubscribeFailure)

    /// The mechanism cannot be performed by this build or this provider.
    case unsupportedMechanism

    /// The metadata was not usable, so nothing was attempted.
    case invalidMetadata

    // MARK: - Identity

    nonisolated enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case requestAccepted
        case requestSent
        case requestFailed
        case browserOpened
        case mailClientOpened
        case handoffFailed
        case unsupportedMechanism
        case invalidMetadata
    }

    var kind: Kind {
        switch self {
        case .requestAccepted: .requestAccepted
        case .requestSent: .requestSent
        case .requestFailed: .requestFailed
        case .browserOpened: .browserOpened
        case .mailClientOpened: .mailClientOpened
        case .handoffFailed: .handoffFailed
        case .unsupportedMechanism: .unsupportedMechanism
        case .invalidMetadata: .invalidMetadata
        }
    }

    /// Whether InboxSweep did the thing the user asked for.
    ///
    /// True for a delivered request and for an opened handoff. Not a claim that anybody was
    /// unsubscribed — see the type's note.
    var didWhatWasAsked: Bool {
        switch self {
        case .requestAccepted, .requestSent, .browserOpened, .mailClientOpened: true
        case .requestFailed, .handoffFailed, .unsupportedMechanism, .invalidMetadata: false
        }
    }

    /// The failure, when there was one.
    var failure: UnsubscribeFailure? {
        switch self {
        case .requestFailed(let failure), .handoffFailed(let failure): failure
        default: nil
        }
    }

    /// Whether trying the same thing again could sensibly work.
    ///
    /// Consulted only to decide whether to *offer* the user a second attempt. Nothing retries
    /// on its own — see ``UnsubscribeRetryPolicy``.
    var isWorthOfferingAgain: Bool { failure?.isWorthOfferingAgain ?? false }

    // MARK: - Wording

    /// The headline. Read these as a set: not one of them says the user is unsubscribed.
    var headline: String {
        switch self {
        case .requestAccepted: "Unsubscribe request sent"
        case .requestSent: "Unsubscribe request sent"
        case .requestFailed: "The unsubscribe request didn't go through"
        case .browserOpened: "Unsubscribe page opened"
        case .mailClientOpened: "Unsubscribe message ready to send"
        case .handoffFailed: "InboxSweep couldn't open that"
        case .unsupportedMechanism: "InboxSweep can't perform this unsubscribe"
        case .invalidMetadata: "This sender's unsubscribe details aren't usable"
        }
    }

    /// The sentence under the headline, which is where the caution actually lives.
    var explanation: String {
        switch self {
        case .requestAccepted(let host, _):
            return """
                \(host) accepted the request. That means it was received — it is not confirmation that \
                you have been removed from the list, which is something only the sender can do and \
                only later mail can show. If messages keep arriving after a week or two, the sender \
                didn't act on it.
                """

        case .requestSent(let host, let status):
            return """
                The request reached \(host), which answered with a redirect (HTTP \(status)) rather than \
                a plain acceptance. InboxSweep doesn't follow that, because it would mean sending a \
                different request than the standard defines. The request was delivered; whether the \
                sender acts on it is not something this answer says.
                """

        case .requestFailed(let failure):
            return failure.explanation

        case .browserOpened(let host):
            return """
                \(host) is open in your browser. InboxSweep stopped there: it hasn't read the page, \
                filled anything in, or submitted anything. Finishing the unsubscribe — including \
                anything the page asks you to confirm — is up to you.
                """

        case .mailClientOpened(let domain):
            return """
                A message to \(domain) is waiting in your mail app, already addressed. \
                InboxSweep has not sent it and cannot: it holds no permission to send mail. \
                Send it yourself if you want the unsubscribe to go through.
                """

        case .handoffFailed(let failure):
            return failure.explanation

        case .unsupportedMechanism:
            return """
                This mechanism isn't one InboxSweep can carry out here. Nothing was sent and nothing \
                was opened.
                """

        case .invalidMetadata:
            return """
                The unsubscribe details on this sender's messages aren't something InboxSweep can act \
                on, and it won't guess at what was meant. Nothing was sent.
                """
        }
    }

    var symbolName: String {
        switch self {
        case .requestAccepted: "checkmark.circle"
        case .requestSent: "paperplane"
        case .browserOpened: "safari"
        case .mailClientOpened: "envelope"
        case .requestFailed, .handoffFailed: "exclamationmark.triangle"
        case .unsupportedMechanism, .invalidMetadata: "minus.circle"
        }
    }
}

/// Why an unsubscribe attempt did not do what was asked.
nonisolated enum UnsubscribeFailure: Error, Hashable, Sendable {

    /// The endpoint answered with an error status.
    case rejectedByEndpoint(host: String, statusCode: Int)

    /// The request never reached anybody.
    case network(reason: String)

    /// The endpoint redirected to an `http` URL. Refused rather than downgraded.
    case insecureRedirect(host: String)

    /// The endpoint redirected to something that is not a web address at all.
    case disallowedRedirectScheme(scheme: String)

    /// More redirects than the policy allows.
    case tooManyRedirects(limit: Int)

    /// A 3xx this app does not know how to honour.
    case unsupportedRedirect(statusCode: Int)

    /// A redirect with no usable `Location`.
    case malformedRedirect

    /// The system declined to open the URL — no browser, no mail client, or a refusal.
    case couldNotOpen

    /// The URL was not one the app is willing to hand to the system at all.
    case refusedDestination

    /// The account connected now is not the one the review was made under.
    case accountChanged

    /// The sender, message, or mechanism the review named is not what is loaded now.
    case reviewIsStale

    /// This confirmation has already been acted on.
    case alreadyPerformed

    /// The provider has no way to send a one-click request.
    case notSupported

    /// Whether offering the user another attempt makes sense.
    ///
    /// Note what is false here. A rejected endpoint is not offered again automatically and a
    /// stale review is not offered at all — the user re-opens the review, which re-reads the
    /// metadata, and decides again.
    var isWorthOfferingAgain: Bool {
        switch self {
        case .network, .couldNotOpen: true
        case .rejectedByEndpoint, .insecureRedirect, .disallowedRedirectScheme, .tooManyRedirects,
             .unsupportedRedirect, .malformedRedirect, .refusedDestination, .accountChanged,
             .reviewIsStale, .alreadyPerformed, .notSupported: false
        }
    }

    var explanation: String {
        switch self {
        case .rejectedByEndpoint(let host, let status):
            return """
                \(host) answered with HTTP \(status), which is a refusal rather than an acceptance. \
                Unsubscribe links expire; this one may have. Nothing else was tried.
                """
        case .network(let reason):
            return "InboxSweep couldn't reach the unsubscribe endpoint. \(reason) Nothing was sent."
        case .insecureRedirect(let host):
            return """
                The endpoint redirected to an unencrypted http:// address at \(host). InboxSweep \
                refuses that rather than downgrading the connection, so the request stopped there.
                """
        case .disallowedRedirectScheme(let scheme):
            return """
                The endpoint redirected to a \(scheme): address, which isn't a web address. \
                InboxSweep follows redirects only from https to https, so nothing further was sent.
                """
        case .tooManyRedirects(let limit):
            return """
                The endpoint redirected more than \(limit) times, which InboxSweep treats as a fault \
                rather than something to keep following.
                """
        case .unsupportedRedirect(let status):
            return """
                The endpoint answered HTTP \(status), a redirect InboxSweep doesn't know how to \
                honour without guessing at what it meant. Nothing further was sent.
                """
        case .malformedRedirect:
            return "The endpoint redirected without saying where to. Nothing further was sent."
        case .couldNotOpen:
            return "macOS didn't open it — there may be no app set up to handle this kind of link."
        case .refusedDestination:
            return """
                That destination isn't one InboxSweep will hand to your browser or mail app. Only \
                https and mailto links are ever opened.
                """
        case .accountChanged:
            return """
                The connected account changed since you opened this review, so InboxSweep didn't act \
                on it. Nothing was sent. Open the review again from the account you mean.
                """
        case .reviewIsStale:
            return """
                The mail this review was based on has changed since you opened it, so InboxSweep \
                didn't act on it — the destination it would send to might no longer be the one you \
                read. Nothing was sent. Open the review again.
                """
        case .alreadyPerformed:
            return "InboxSweep already acted on this confirmation. Nothing was sent a second time."
        case .notSupported:
            return "This mailbox has no way to send an unsubscribe request. Nothing was sent."
        }
    }

    var headline: String {
        switch self {
        case .rejectedByEndpoint: "The sender's server refused the request"
        case .network: "Couldn't reach the unsubscribe endpoint"
        case .insecureRedirect: "The endpoint redirected to an insecure address"
        case .disallowedRedirectScheme: "The endpoint redirected somewhere InboxSweep won't follow"
        case .tooManyRedirects: "Too many redirects"
        case .unsupportedRedirect: "An answer InboxSweep won't act on"
        case .malformedRedirect: "The endpoint redirected to nowhere"
        case .couldNotOpen: "Nothing opened"
        case .refusedDestination: "InboxSweep won't open that link"
        case .accountChanged: "The connected account changed"
        case .reviewIsStale: "This review is out of date"
        case .alreadyPerformed: "That's already been done"
        case .notSupported: "This mailbox can't send unsubscribe requests"
        }
    }
}

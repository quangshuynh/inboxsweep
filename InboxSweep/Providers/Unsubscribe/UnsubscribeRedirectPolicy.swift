import Foundation

/// What InboxSweep does when an unsubscribe endpoint answers with a redirect.
///
/// ### Why this is written down rather than inherited
///
/// `URLSession` follows redirects by default, up to twenty of them, across schemes, converting
/// `POST` to `GET` on the way — and it does all of that inside `data(for:)` where no test can
/// see it. For a Gmail API call that default is fine. For a `POST` to a URL a stranger put in a
/// mail header it is not: the app would be following that stranger's `Location` header to
/// wherever it pointed, and nobody could say afterwards where the request had gone.
///
/// So redirects are not followed by the session at all. ``UnsubscribeHTTPTransport`` refuses
/// them at the delegate, and ``OneClickUnsubscribeClient`` performs the loop itself against
/// this policy — which makes the whole of it a value a test can assert on.
///
/// ### The policy
///
/// - **Method-preserving redirects only.** 307 and 308 are followed, because they re-send the
///   same `POST` with the same body — the same request, at a new address. 301, 302, and 303 are
///   **not** followed: every one of them means "do a `GET` instead", and a `GET` to a landing
///   page is not the request RFC 8058 defines. Those are terminal, and reported as
///   ``UnsubscribeOutcome/requestSent`` — the endpoint received the request, and what it did
///   with it is not something a redirect can tell us.
/// - **HTTPS to HTTPS only.** A `Location` naming `http` is refused outright rather than
///   downgraded silently. So is `mailto`, `javascript`, `data`, `file`, and every custom
///   scheme.
/// - **Bounded.** At most ``maximumRedirects`` hops, after which the attempt fails rather than
///   continuing. A redirect loop is a failure, not a reason to keep asking.
/// - **Nothing is carried across a hop but the body.** No cookie is stored or sent, no
///   `Authorization` header exists to forward, and the payload is the same constant it was on
///   the first hop.
nonisolated enum UnsubscribeRedirectPolicy {

    /// How many hops are allowed. Three is generous for a link that should not redirect at all.
    static let maximumRedirects = 3

    /// The statuses that re-send the same request, and are therefore the only ones followed.
    static let methodPreservingStatuses: Set<Int> = [307, 308]

    /// The statuses that mean "look somewhere else with a GET", which this app will not do.
    static let methodChangingStatuses: Set<Int> = [301, 302, 303]

    /// What to do about one response.
    nonisolated enum Decision: Hashable, Sendable {

        /// Not a redirect. The response is the answer.
        case useResponse

        /// Re-send the identical POST to this validated HTTPS URL.
        case follow(HTTPSUnsubscribeURL)

        /// A redirect that changes the method. The request reached the endpoint; the app stops
        /// here rather than issuing a different request than the standard defines.
        case stopAtMethodChange

        /// Refuse, and say why.
        case refuse(UnsubscribeFailure)
    }

    /// Applies the policy to one response.
    ///
    /// - Parameters:
    ///   - statusCode: The status the endpoint returned.
    ///   - location: Its `Location` header, if it sent one.
    ///   - base: The URL the request was sent to, for resolving a relative `Location`.
    ///   - redirectsSoFar: How many hops have already been taken.
    static func decide(
        statusCode: Int,
        location: String?,
        base: HTTPSUnsubscribeURL,
        redirectsSoFar: Int
    ) -> Decision {
        guard (300..<400).contains(statusCode) else { return .useResponse }

        if methodChangingStatuses.contains(statusCode) { return .stopAtMethodChange }
        guard methodPreservingStatuses.contains(statusCode) else {
            // 300, 304, 305, 306, or anything else in the 3xx range: not a redirect this app
            // knows how to honour, and guessing is the thing the policy exists to prevent.
            return .refuse(.unsupportedRedirect(statusCode: statusCode))
        }

        guard redirectsSoFar < maximumRedirects else {
            return .refuse(.tooManyRedirects(limit: maximumRedirects))
        }

        guard let location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refuse(.malformedRedirect)
        }

        // Resolved against the current URL, because a `Location` may legitimately be relative —
        // and a relative one can only ever stay on the same https origin, which is the safe
        // direction.
        guard let resolved = URL(string: location, relativeTo: base.url)?.absoluteURL else {
            return .refuse(.malformedRedirect)
        }

        guard let next = HTTPSUnsubscribeURL(resolved) else {
            let scheme = resolved.scheme?.lowercased()
            return .refuse(
                scheme == "http"
                    ? .insecureRedirect(host: resolved.host(percentEncoded: false) ?? "")
                    : .disallowedRedirectScheme(scheme: scheme ?? "none")
            )
        }

        return .follow(next)
    }
}

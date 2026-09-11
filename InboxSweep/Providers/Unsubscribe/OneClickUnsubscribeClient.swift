import Foundation

/// Sends the one request RFC 8058 defines, and nothing else, over a transport of its own.
///
/// ### What goes out
///
/// ```
/// POST <the exact URL from the header>
/// Content-Type: application/x-www-form-urlencoded
///
/// List-Unsubscribe=One-Click
/// ```
///
/// That is the whole request. Read the list of what is *not* in it, because that list is the
/// feature:
///
/// - **No `Authorization` header.** This client has never seen a Google access token: it is
///   not given one, there is no parameter for one, and it shares no type with the Gmail API
///   client that holds one. A token cannot reach a sender's server by mistake because there is
///   no path along which it could travel.
/// - **No cookies.** The session is ephemeral and `httpShouldHandleCookies` is off, so nothing
///   from the user's browser is attached and nothing this endpoint sets is kept.
/// - **No mailbox content.** No message identifier, no subject, no sender address, and not the
///   user's own address. RFC 8058 does not ask for any of it, and the endpoint already knows
///   who it sent the link to.
/// - **No added query parameters.** The URL is used byte-for-byte as the header gave it.
/// - **No retries.** See ``UnsubscribeRetryPolicy``.
///
/// ### Redirects
///
/// Handled here rather than by `URLSession`, against ``UnsubscribeRedirectPolicy``, so the
/// policy is a value a test can drive rather than a default nobody can see.
nonisolated struct OneClickUnsubscribeClient: MailUnsubscribing {

    private let transport: any HTTPTransport

    /// The transport is injected, and in production it is
    /// ``UnsubscribeHTTPTransport``, *not* the one the Gmail adapter uses.
    ///
    /// Separate objects rather than a shared one with different headers: a shared transport
    /// would be one place where a Gmail request and an unsubscribe request could be confused
    /// for each other, and the whole point of this file is that they cannot be.
    init(transport: any HTTPTransport = UnsubscribeHTTPTransport()) {
        self.transport = transport
    }

    func unsubscribeCapability() async -> UnsubscribeCapability { .oneClickSupported }

    func submitOneClickUnsubscribe(
        _ request: OneClickUnsubscribeRequest
    ) async throws -> OneClickUnsubscribeReceipt {
        var endpoint = request.endpoint
        var redirects = 0

        while true {
            let response: HTTPResponse
            do {
                response = try await transport.send(Self.urlRequest(for: endpoint))
            } catch is CancellationError {
                throw UnsubscribeFailure.network(reason: "The request was cancelled.")
            } catch let failure as UnsubscribeFailure {
                throw failure
            } catch {
                throw UnsubscribeFailure.network(reason: Self.networkReason(for: error))
            }

            switch UnsubscribeRedirectPolicy.decide(
                statusCode: response.statusCode,
                location: response.header("Location"),
                base: endpoint,
                redirectsSoFar: redirects
            ) {
            case .useResponse:
                guard (200..<300).contains(response.statusCode) else {
                    throw UnsubscribeFailure.rejectedByEndpoint(
                        host: endpoint.host,
                        statusCode: response.statusCode
                    )
                }
                return OneClickUnsubscribeReceipt(
                    host: endpoint.host,
                    statusCode: response.statusCode,
                    redirectCount: redirects
                )

            case .stopAtMethodChange:
                // The request was delivered; the endpoint is pointing at a page. Reported as a
                // receipt carrying the 3xx, which the outcome turns into "request sent" rather
                // than "accepted": the one place in the app where those two differ in wording.
                return OneClickUnsubscribeReceipt(
                    host: endpoint.host,
                    statusCode: response.statusCode,
                    redirectCount: redirects
                )

            case .follow(let next):
                endpoint = next
                redirects += 1

            case .refuse(let failure):
                throw failure
            }
        }
    }

    /// Builds the request. The only place in the app that constructs one.
    ///
    /// `static` and `internal` so a test can assert on the exact `URLRequest`: method, URL,
    /// body, content type, and the headers that are absent, without a transport in the way.
    static func urlRequest(for endpoint: HTTPSUnsubscribeURL) -> URLRequest {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = OneClickUnsubscribeBody.method
        request.httpBody = OneClickUnsubscribeBody.data
        request.setValue(OneClickUnsubscribeBody.contentType, forHTTPHeaderField: "Content-Type")
        // Off at the request as well as on the session: two independent places have to change
        // before this request could carry a cookie.
        request.httpShouldHandleCookies = false
        // Neither the session nor the request may reuse anything the endpoint cached.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    /// A short, secret-free reason. Deliberately not the error's own description, which can
    /// name a URL.
    private static func networkReason(for error: Error) -> String {
        guard let urlError = error as? URLError else { return "The connection failed." }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "This Mac doesn't seem to be online."
        case .timedOut:
            return "The endpoint didn't answer in time."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "The unsubscribe host couldn't be reached."
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot:
            return "The secure connection to the unsubscribe host couldn't be established."
        default:
            return "The connection failed."
        }
    }
}

/// How often an unsubscribe write is retried automatically: never.
///
/// ### Why this is a type and not an omission
///
/// The Gmail adapter retries: a 429 or a 503 on a read is a reason to wait and ask again, and
/// ``GmailAPIClient`` does. Copying that here would have been the natural thing to do and would
/// have been wrong. A one-click unsubscribe is a `POST` to somebody else's server; the standard
/// says nothing about whether it is idempotent, the endpoint's own implementation is unknown,
/// and a retry that the user did not ask for is a second unsubscribe request sent under an
/// authorization they gave once.
///
/// So there is no backoff, no jitter, no attempt counter, and no queue. One confirmation is one
/// request. A failure is reported to the user, who can decide to ask again, which is a new,
/// explicit action, recorded as its own entry.
///
/// Naming it makes the absence deliberate and testable rather than an oversight somebody
/// helpfully fixes later.
nonisolated enum UnsubscribeRetryPolicy {

    /// How many times a failed unsubscribe request is re-sent without the user asking: zero.
    static let automaticRetries = 0

    /// Whether anything in the app may re-send an unsubscribe request on its own.
    static let allowsBackgroundRetry = false

    /// Why, in a sentence the UI can show.
    static let explanation = """
        InboxSweep sends an unsubscribe request once. It never retries on its own and never sends \
        one in the background: a repeat would be a second request to the sender under permission \
        you gave once. If one fails, you decide whether to ask again.
        """
}

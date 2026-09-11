import Foundation

/// The network seam for unsubscribe requests, and only for those.
///
/// A second transport rather than the Gmail one with different headers. The two carry
/// completely different things to completely different places — one carries a Google access
/// token to `gmail.googleapis.com`, the other carries a fixed twenty-six-byte form body to a
/// host named in a stranger's mail header — and sharing an object between them would be the one
/// place those could be confused.
///
/// Its session is configured for exactly that job:
///
/// - **Ephemeral**, so nothing passing through is written to disk;
/// - **No cookie storage**, and `httpCookieAcceptPolicy = .never`, so nothing a sender's
///   endpoint sets is kept and nothing from anywhere else is attached;
/// - **No credential storage**, so no keychain or session credential can be offered to a
///   challenge;
/// - **No URL cache**;
/// - **Redirects refused at the delegate.** `URLSession` would otherwise follow up to twenty of
///   them, across schemes, turning the `POST` into a `GET` on the way, entirely invisibly.
///   Returning `nil` from the redirect delegate hands the 3xx response back to the caller
///   instead, so ``UnsubscribeRedirectPolicy`` decides — in code a test can drive.
nonisolated final class UnsubscribeHTTPTransport: NSObject, HTTPTransport, @unchecked Sendable {

    private let session: URLSession

    /// How long a single unsubscribe request may take.
    ///
    /// Shorter than the Gmail transport's thirty seconds. There is no page to render and no
    /// pagination behind this; an endpoint that has not answered in fifteen seconds is one the
    /// user should be told about rather than waited on.
    static let timeout: TimeInterval = 15

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.waitsForConnectivity = false
        // Nothing about the app, the account, or the Mac. The default would name the app and
        // its build, which is more than an unsubscribe endpoint needs to know.
        configuration.httpAdditionalHeaders = [:]

        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
        super.init()
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        // The delegate refusing redirects is what makes the 3xx visible to the client. It is
        // per-task rather than on the session so the refusal cannot be lost if this type ever
        // gains a second caller with its own session.
        let (data, response) = try await session.data(for: request, delegate: RedirectRefusingDelegate())

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UnsubscribeFailure.network(reason: "The endpoint returned something that wasn't an HTTP response.")
        }

        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }

        return HTTPResponse(statusCode: httpResponse.statusCode, headers: headers, body: data)
    }
}

/// Hands a 3xx back to the caller instead of following it.
private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // `nil` means "do not follow": the redirect response becomes the task's result, which
        // is exactly what `OneClickUnsubscribeClient` needs in order to apply the policy itself.
        completionHandler(nil)
    }
}

import Foundation
@testable import InboxSweep

/// A stand-in for the network that records what was sent and replays canned responses.
///
/// Every Gmail adapter test runs through this: no test in this target opens a socket, needs a
/// Google account, or touches a real mailbox.
final class RecordingHTTPTransport: HTTPTransport, @unchecked Sendable {

    /// Called for each request. `attempt` is how many requests for this same URL have already
    /// been made, which is what lets a test say "fail the first time, succeed the second".
    typealias Handler = @Sendable (_ request: URLRequest, _ attempt: Int) async throws -> HTTPResponse

    private let handler: Handler
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var attemptsByURL: [String: Int] = [:]
    private var inFlight = 0
    private var observedPeakConcurrency = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Convenience for tests that only care about one response per URL pattern.
    convenience init(routes: [Route]) {
        self.init { request, _ in
            let url = request.url?.absoluteString ?? ""
            guard let route = routes.first(where: { url.contains($0.urlContains) }) else {
                return HTTPResponse(statusCode: 418, body: Data("unrouted: \(url)".utf8))
            }
            return try await route.response(request)
        }
    }

    struct Route {
        let urlContains: String
        let response: @Sendable (URLRequest) async throws -> HTTPResponse

        static func json(_ urlContains: String, _ json: String, status: Int = 200) -> Route {
            Route(urlContains: urlContains) { _ in
                HTTPResponse(
                    statusCode: status,
                    headers: ["Content-Type": "application/json"],
                    body: Data(json.utf8)
                )
            }
        }
    }

    // MARK: - Inspection

    var requests: [URLRequest] { lock.withLock { recorded } }
    var requestCount: Int { lock.withLock { recorded.count } }
    var peakConcurrency: Int { lock.withLock { observedPeakConcurrency } }

    func requests(matching substring: String) -> [URLRequest] {
        requests.filter { ($0.url?.absoluteString ?? "").contains(substring) }
    }

    // MARK: - HTTPTransport

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let key = request.url?.absoluteString ?? ""
        let attempt = lock.withLock {
            recorded.append(request)
            let attempt = attemptsByURL[key, default: 0]
            attemptsByURL[key] = attempt + 1
            inFlight += 1
            observedPeakConcurrency = max(observedPeakConcurrency, inFlight)
            return attempt
        }

        defer { lock.withLock { inFlight -= 1 } }
        return try await handler(request, attempt)
    }
}

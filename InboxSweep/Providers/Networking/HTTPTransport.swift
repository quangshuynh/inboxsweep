import Foundation

/// A minimal HTTP response, decoupled from `URLSession` so adapters can be tested offline.
nonisolated struct HTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// Case-insensitive header lookup, as HTTP header names are not case-sensitive.
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// The single seam between the Gmail adapter and the network.
///
/// Every request the adapter makes goes through this protocol, which is what allows the whole
/// adapter: request construction, status mapping, normalization, pagination, concurrency,
/// to be exercised in tests against recorded fixtures, with no Gmail account involved.
nonisolated protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// The production transport.
nonisolated struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    /// Creates a transport backed by an ephemeral session.
    ///
    /// Ephemeral means no on-disk URL cache, cookie store, or credential store, so message
    /// metadata that passes through here is never written to disk by the networking layer.
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MailProviderError.malformedResponse(reason: "The provider returned a non-HTTP response.")
        }

        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }

        return HTTPResponse(statusCode: httpResponse.statusCode, headers: headers, body: data)
    }
}

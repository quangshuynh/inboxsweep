import Foundation

/// Sends authorized, read-only requests to the Gmail API and decodes the results.
///
/// Responsibilities kept here on purpose: attaching the access token, retrying the failures
/// that are worth retrying, and turning HTTP status codes into ``MailProviderError``. It does
/// not know what a sender is, and the domain does not know this type exists.
nonisolated struct GmailAPIClient: Sendable {

    /// How the client backs off from throttling and transient provider failures.
    struct RetryPolicy: Sendable, Equatable {
        var maximumAttempts: Int = 3
        var initialDelay: TimeInterval = 1
        var multiplier: Double = 2

        /// No waiting, for tests that need to exercise retry paths quickly.
        static let immediate = RetryPolicy(maximumAttempts: 3, initialDelay: 0, multiplier: 1)
    }

    private let transport: HTTPTransport
    private let accessToken: @Sendable () async throws -> GmailAccessToken
    private let retryPolicy: RetryPolicy
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    init(
        transport: HTTPTransport,
        accessToken: @escaping @Sendable () async throws -> GmailAccessToken,
        retryPolicy: RetryPolicy = RetryPolicy(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            guard seconds > 0 else { return }
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.transport = transport
        self.accessToken = accessToken
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    // MARK: - Reads

    func profile() async throws -> GmailDTO.Profile {
        try await get(GmailAPIEndpoint.profile())
    }

    func listMessages(
        limit: Int,
        pageToken: MailPageToken?,
        scope: MailboxScope
    ) async throws -> GmailDTO.MessageList {
        try await get(GmailAPIEndpoint.listMessages(limit: limit, pageToken: pageToken, scope: scope))
    }

    func messageMetadata(id: MailMessageID) async throws -> GmailDTO.Message {
        try await get(GmailAPIEndpoint.messageMetadata(id: id))
    }

    // MARK: - Transport

    private func get<Response: Decodable>(_ endpoint: GmailAPIRequest) async throws -> Response {
        let response = try await send(endpoint)
        do {
            return try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            throw MailProviderError.malformedResponse(
                reason: "Gmail's response didn't match the format InboxSweep expects."
            )
        }
    }

    private func send(_ endpoint: GmailAPIRequest) async throws -> HTTPResponse {
        var delay = retryPolicy.initialDelay
        var lastError: MailProviderError = .providerFailure(
            statusCode: 0,
            reason: "Gmail didn't respond."
        )

        for attempt in 1...max(retryPolicy.maximumAttempts, 1) {
            try Task.checkCancellation()

            let token = try await accessToken()
            let request = endpoint.urlRequest(authorizedWith: token.value)

            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch {
                let wrapped = MailProviderError.wrapping(error)
                // A dropped connection is worth one more try; a cancelled task is not.
                guard case .network = wrapped, attempt < retryPolicy.maximumAttempts else { throw wrapped }
                lastError = wrapped
                try await backOff(seconds: delay, retryAfter: nil)
                delay *= retryPolicy.multiplier
                continue
            }

            if response.isSuccess { return response }

            let error = Self.mapFailure(response)
            guard Self.isWorthRetrying(response.statusCode), attempt < retryPolicy.maximumAttempts else {
                throw error
            }

            lastError = error
            try await backOff(seconds: delay, retryAfter: response.header("Retry-After"))
            delay *= retryPolicy.multiplier
        }

        throw lastError
    }

    private func backOff(seconds: TimeInterval, retryAfter: String?) async throws {
        // Gmail's own guidance wins over our schedule when it sends one.
        let requested = retryAfter.flatMap(TimeInterval.init)
        do {
            try await sleep(min(max(requested ?? seconds, 0), 30))
        } catch {
            throw MailProviderError.wrapping(error)
        }
    }

    /// Throttling and server-side faults are transient; everything else is not.
    static func isWorthRetrying(_ statusCode: Int) -> Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }

    /// Turns a failed HTTP response into a user-explainable error.
    ///
    /// Only Google's short `reason`/`status` codes are read out of the body; the message text
    /// and any payload are deliberately not forwarded to the UI.
    static func mapFailure(_ response: HTTPResponse) -> MailProviderError {
        let envelope = try? JSONDecoder().decode(GmailDTO.ErrorEnvelope.self, from: response.body)
        let reasons = Set((envelope?.error?.errors ?? []).compactMap(\.reason))
        let status = envelope?.error?.status

        switch response.statusCode {
        case 401:
            return .authorizationExpired

        case 403:
            if reasons.contains("rateLimitExceeded") || reasons.contains("userRateLimitExceeded") {
                return .providerFailure(statusCode: 403, reason: "Gmail is rate-limiting this account.")
            }
            return .insufficientPermissions(
                reason: "Gmail declined the request. InboxSweep may need to be reconnected with read-only access."
            )

        case 429:
            return .providerFailure(statusCode: 429, reason: "Gmail is rate-limiting this account.")

        case 404:
            return .providerFailure(statusCode: 404, reason: "Gmail couldn't find what InboxSweep asked for.")

        case 500...599:
            return .providerFailure(statusCode: response.statusCode, reason: "Gmail is temporarily unavailable.")

        default:
            let detail = status.map { "Gmail reported \($0)." } ?? "Gmail rejected the request."
            return .providerFailure(statusCode: response.statusCode, reason: detail)
        }
    }
}

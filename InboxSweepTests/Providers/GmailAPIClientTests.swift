import Foundation
import Testing
@testable import InboxSweep

@Suite("Gmail API client")
struct GmailAPIClientTests {

    private func client(
        transport: HTTPTransport,
        retryPolicy: GmailAPIClient.RetryPolicy = .immediate
    ) -> GmailAPIClient {
        GmailAPIClient(
            transport: transport,
            accessToken: { GmailAccessToken(value: "test-token", expiresAt: .distantFuture, grantedScopes: GmailScope.requested) },
            retryPolicy: retryPolicy,
            sleep: { _ in }
        )
    }

    @Test("Requests carry a bearer token and ask for JSON")
    func authorizesRequests() async throws {
        let transport = RecordingHTTPTransport(routes: [.json("profile", GmailFixtures.profileJSON())])
        _ = try await client(transport: transport).profile()

        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("Throttling is retried and then succeeds")
    func retriesThrottling() async throws {
        let transport = RecordingHTTPTransport { _, attempt in
            attempt == 0
                ? HTTPResponse(statusCode: 429, headers: ["Retry-After": "0"], body: Data())
                : HTTPResponse(statusCode: 200, body: Data(GmailFixtures.profileJSON().utf8))
        }

        let profile = try await client(transport: transport).profile()

        #expect(profile.emailAddress == "sample.user@example.com")
        #expect(transport.requestCount == 2)
    }

    @Test("Retrying gives up after the configured number of attempts")
    func stopsRetrying() async {
        let transport = RecordingHTTPTransport { _, _ in HTTPResponse(statusCode: 503) }

        await #expect(throws: MailProviderError.providerFailure(
            statusCode: 503,
            reason: "Gmail is temporarily unavailable."
        )) {
            _ = try await client(transport: transport).profile()
        }

        #expect(transport.requestCount == 3)
    }

    @Test("Failures that cannot be fixed by waiting are not retried")
    func doesNotRetryPermanentFailures() async {
        let transport = RecordingHTTPTransport { _, _ in HTTPResponse(statusCode: 401) }

        await #expect(throws: MailProviderError.authorizationExpired) {
            _ = try await client(transport: transport).profile()
        }

        #expect(transport.requestCount == 1)
    }

    @Test("A malformed body is reported as such, not as a provider outage")
    func reportsMalformedResponses() async {
        let transport = RecordingHTTPTransport { _, _ in
            HTTPResponse(statusCode: 200, body: Data("{ this is not json".utf8))
        }

        await #expect(throws: MailProviderError.malformedResponse(
            reason: "Gmail's response didn't match the format InboxSweep expects."
        )) {
            _ = try await client(transport: transport).profile()
        }
    }

    // MARK: - Status mapping

    @Test("HTTP failures map to errors the UI can explain")
    func mapsStatusCodes() {
        #expect(GmailAPIClient.mapFailure(HTTPResponse(statusCode: 401)) == .authorizationExpired)

        #expect(GmailAPIClient.mapFailure(HTTPResponse(
            statusCode: 403,
            body: Data(GmailFixtures.apiErrorJSON(status: "PERMISSION_DENIED").utf8)
        )).requiresReauthentication)

        // A 403 can also mean throttling, which is transient and must not send the user
        // through a pointless re-consent.
        let throttled = GmailAPIClient.mapFailure(HTTPResponse(
            statusCode: 403,
            body: Data(GmailFixtures.apiErrorJSON(status: "RESOURCE_EXHAUSTED", reason: "userRateLimitExceeded").utf8)
        ))
        #expect(!throttled.requiresReauthentication)
        #expect(throttled.isRetryable)

        #expect(GmailAPIClient.mapFailure(HTTPResponse(statusCode: 429)).isRetryable)
        #expect(GmailAPIClient.mapFailure(HTTPResponse(statusCode: 500)).isRetryable)
    }

    @Test("Only throttling and server faults are worth retrying", arguments: [
        (429, true), (500, true), (503, true), (400, false), (401, false), (403, false), (404, false),
    ])
    func classifiesRetryableStatuses(statusCode: Int, expected: Bool) {
        #expect(GmailAPIClient.isWorthRetrying(statusCode) == expected)
    }

    @Test("Error text never echoes the provider's response body")
    func doesNotLeakResponseBodies() {
        let secretish = """
        { "error": { "code": 403, "message": "token ya29.SUPER-SECRET leaked here", "status": "PERMISSION_DENIED" } }
        """
        let error = GmailAPIClient.mapFailure(HTTPResponse(statusCode: 403, body: Data(secretish.utf8)))
        let displayed = [error.errorDescription, error.failureReason, error.recoverySuggestion]
            .compactMap(\.self)
            .joined(separator: " ")

        #expect(!displayed.contains("ya29"))
        #expect(!displayed.contains("SUPER-SECRET"))
    }

    @Test("Cancellation is reported as cancellation, not as a provider failure")
    func propagatesCancellation() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            try await Task.sleep(for: .seconds(60))
            return HTTPResponse(statusCode: 200)
        }
        let client = client(transport: transport)

        let task = Task { try await client.profile() }
        // Let the request reach the transport before cancelling it.
        while transport.requestCount == 0 { await Task.yield() }
        task.cancel()

        await #expect(throws: MailProviderError.cancelled) { try await task.value }
    }
}

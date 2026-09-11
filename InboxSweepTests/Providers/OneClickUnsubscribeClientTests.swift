import Foundation
import Testing
@testable import InboxSweep

/// Exactly what goes out over the wire for a one-click unsubscribe, and exactly what does not.
///
/// Every case here runs through ``RecordingHTTPTransport``: no socket is opened, and every host
/// named is under `.example`, which no registry will ever delegate.
@Suite("One-click unsubscribe over the wire")
struct OneClickUnsubscribeClientTests {

    private static let endpoint = HTTPSUnsubscribeURL(string: "https://lists.example/u/abc?token=xyz")!

    private static func request(operationID: UUID = UUID()) -> OneClickUnsubscribeRequest {
        OneClickUnsubscribeRequest(
            endpoint: endpoint,
            accountAddress: "someone@example.com",
            operationID: operationID
        )
    }

    private static func accepting(_ status: Int = 200) -> RecordingHTTPTransport {
        RecordingHTTPTransport { _, _ in HTTPResponse(statusCode: status) }
    }

    // MARK: - The request itself

    @Test("The request is a POST to the exact URL, with the protocol-defined body")
    func sendsExactlyTheStandardRequest() async throws {
        let transport = Self.accepting()
        _ = try await OneClickUnsubscribeClient(transport: transport).submitOneClickUnsubscribe(Self.request())

        #expect(transport.requestCount == 1)
        let sent = try #require(transport.requests.first)

        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://lists.example/u/abc?token=xyz")
        #expect(sent.httpBody == Data("List-Unsubscribe=One-Click".utf8))
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    }

    @Test("The URL is used byte for byte — nothing is appended, removed, or reordered")
    func urlIsNotRewritten() async throws {
        // A sender's own tracking token is theirs. One InboxSweep added would be InboxSweep
        // telling a third party something about this user.
        let original = "https://lists.example/u/abc?token=xyz&list=42"
        let transport = Self.accepting()
        _ = try await OneClickUnsubscribeClient(transport: transport).submitOneClickUnsubscribe(
            OneClickUnsubscribeRequest(
                endpoint: HTTPSUnsubscribeURL(string: original)!,
                accountAddress: "someone@example.com"
            )
        )

        #expect(transport.requests.first?.url?.absoluteString == original)
    }

    @Test("No Google token, no credential, and no header InboxSweep did not set")
    func carriesNoCredential() async throws {
        let transport = Self.accepting()
        _ = try await OneClickUnsubscribeClient(transport: transport).submitOneClickUnsubscribe(Self.request())

        let sent = try #require(transport.requests.first)
        let headers = sent.allHTTPHeaderFields ?? [:]

        // The one that matters most, asserted by name and by value-shape.
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!headers.values.contains { $0.lowercased().hasPrefix("bearer") })
        #expect(!headers.values.contains { $0.contains("ya29.") })
        #expect(sent.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(!sent.httpShouldHandleCookies)

        // And the whole header set is the one header the standard asks for.
        #expect(Set(headers.keys) == ["Content-Type"])
    }

    @Test("Nothing about the mailbox goes with it — no address, no message id, no subject")
    func carriesNoMailboxContent() async throws {
        let transport = Self.accepting()
        _ = try await OneClickUnsubscribeClient(transport: transport).submitOneClickUnsubscribe(
            OneClickUnsubscribeRequest(
                endpoint: Self.endpoint,
                accountAddress: "someone@example.com",
                operationID: UUID()
            )
        )

        let sent = try #require(transport.requests.first)
        let everythingSent = [
            sent.url?.absoluteString ?? "",
            String(data: sent.httpBody ?? Data(), encoding: .utf8) ?? "",
            (sent.allHTTPHeaderFields ?? [:]).map { "\($0.key):\($0.value)" }.joined(separator: " "),
        ].joined(separator: " ")

        // The account address is on the request object because the *session* re-checks it. It is
        // not on the wire, and this is what says so.
        #expect(!everythingSent.contains("someone@example.com"))
        #expect(!everythingSent.contains("example.com"))
        // The body is the constant and only the constant.
        #expect(sent.httpBody == OneClickUnsubscribeBody.data)
    }

    @Test("The body is a constant, so a payload cannot be assembled from anything in memory")
    func bodyIsAConstant() {
        #expect(OneClickUnsubscribeBody.formEncoded == "List-Unsubscribe=One-Click")
        #expect(OneClickUnsubscribeBody.method == "POST")
        #expect(OneClickUnsubscribeBody.contentType == "application/x-www-form-urlencoded")
    }

    // MARK: - Outcomes

    @Test("A 2xx is an accepted request and nothing more")
    func acceptedResponse() async throws {
        for status in [200, 201, 202, 204] {
            let receipt = try await OneClickUnsubscribeClient(transport: Self.accepting(status))
                .submitOneClickUnsubscribe(Self.request())

            #expect(receipt.wasAccepted)
            #expect(receipt.statusCode == status)
            #expect(receipt.host == "lists.example")
            #expect(receipt.redirectCount == 0)
        }
    }

    @Test("An error status is a refusal, reported with the host and the code")
    func rejectedResponse() async {
        for status in [400, 403, 404, 410, 500, 503] {
            await #expect(throws: UnsubscribeFailure.rejectedByEndpoint(host: "lists.example", statusCode: status)) {
                try await OneClickUnsubscribeClient(transport: Self.accepting(status))
                    .submitOneClickUnsubscribe(Self.request())
            }
        }
    }

    @Test("A failed request is sent once and never retried on its own")
    func neverRetries() async {
        // The Gmail adapter backs off and retries a 429. This must not, because a retry is a
        // second unsubscribe request under an authorization the user gave once.
        let transport = RecordingHTTPTransport { _, _ in HTTPResponse(statusCode: 429) }

        _ = try? await OneClickUnsubscribeClient(transport: transport).submitOneClickUnsubscribe(Self.request())

        #expect(transport.requestCount == 1)
        #expect(UnsubscribeRetryPolicy.automaticRetries == 0)
        #expect(!UnsubscribeRetryPolicy.allowsBackgroundRetry)

        // A 503 with a Retry-After is the shape most likely to tempt a retry. It does not.
        let busy = RecordingHTTPTransport { _, _ in
            HTTPResponse(statusCode: 503, headers: ["Retry-After": "1"])
        }
        _ = try? await OneClickUnsubscribeClient(transport: busy).submitOneClickUnsubscribe(Self.request())
        #expect(busy.requestCount == 1)
    }

    // MARK: - Redirects

    @Test("A 307 and a 308 re-send the identical POST to the new https URL")
    func followsMethodPreservingRedirects() async throws {
        for status in [307, 308] {
            let transport = RecordingHTTPTransport { request, _ in
                if request.url?.host == "lists.example" {
                    return HTTPResponse(statusCode: status, headers: ["Location": "https://moved.example/u/abc"])
                }
                return HTTPResponse(statusCode: 200)
            }

            let receipt = try await OneClickUnsubscribeClient(transport: transport)
                .submitOneClickUnsubscribe(Self.request())

            #expect(receipt.wasAccepted)
            #expect(receipt.host == "moved.example")
            #expect(receipt.redirectCount == 1)

            // The same request, at the new address: same method, same body, still no credential.
            let second = try #require(transport.requests.last)
            #expect(second.httpMethod == "POST")
            #expect(second.httpBody == OneClickUnsubscribeBody.data)
            #expect(second.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    @Test("A 301, 302, or 303 ends the attempt rather than becoming a GET")
    func doesNotFollowMethodChangingRedirects() async throws {
        for status in [301, 302, 303] {
            let transport = RecordingHTTPTransport { _, _ in
                HTTPResponse(statusCode: status, headers: ["Location": "https://landing.example/thanks"])
            }

            let receipt = try await OneClickUnsubscribeClient(transport: transport)
                .submitOneClickUnsubscribe(Self.request())

            // One request, to the original host. The landing page was never fetched.
            #expect(transport.requestCount == 1)
            #expect(transport.requests(matching: "landing.example").isEmpty)
            // And the receipt is not an acceptance, which is what makes the wording "sent".
            #expect(!receipt.wasAccepted)
            #expect(receipt.statusCode == status)
        }
    }

    @Test("A redirect to http is refused rather than followed or upgraded")
    func refusesInsecureRedirect() async {
        let transport = RecordingHTTPTransport { _, _ in
            HTTPResponse(statusCode: 308, headers: ["Location": "http://downgrade.example/u"])
        }

        await #expect(throws: UnsubscribeFailure.insecureRedirect(host: "downgrade.example")) {
            try await OneClickUnsubscribeClient(transport: transport).submitOneClickUnsubscribe(Self.request())
        }
        #expect(transport.requestCount == 1)
        #expect(transport.requests(matching: "downgrade.example").isEmpty)
    }

    @Test("A redirect to a non-web scheme is refused")
    func refusesNonWebRedirect() async {
        for (location, scheme) in [("mailto:a@lists.example", "mailto"), ("javascript:alert(1)", "javascript"), ("file:///tmp/x", "file")] {
            let transport = RecordingHTTPTransport { _, _ in
                HTTPResponse(statusCode: 307, headers: ["Location": location])
            }

            await #expect(throws: UnsubscribeFailure.disallowedRedirectScheme(scheme: scheme)) {
                try await OneClickUnsubscribeClient(transport: transport).submitOneClickUnsubscribe(Self.request())
            }
            #expect(transport.requestCount == 1)
        }
    }

    @Test("Redirects are bounded, and a loop fails instead of continuing")
    func boundsRedirects() async {
        // Each hop points at a host it has not been to yet, so the client is following a chain
        // rather than looping on one URL — which is the case a per-URL attempt counter would
        // miss and a hop counter catches.
        let transport = RecordingHTTPTransport { request, _ in
            let next = (request.url?.host ?? "") + ".onward"
            return HTTPResponse(statusCode: 308, headers: ["Location": "https://\(next).example/u"])
        }

        await #expect(throws: UnsubscribeFailure.tooManyRedirects(limit: UnsubscribeRedirectPolicy.maximumRedirects)) {
            try await OneClickUnsubscribeClient(transport: transport).submitOneClickUnsubscribe(Self.request())
        }

        // The first request plus the allowed hops, and then it stops.
        #expect(transport.requestCount == UnsubscribeRedirectPolicy.maximumRedirects + 1)
    }

    @Test("A redirect with no Location is refused rather than guessed at")
    func refusesRedirectWithoutLocation() async {
        let transport = RecordingHTTPTransport { _, _ in HTTPResponse(statusCode: 308) }

        await #expect(throws: UnsubscribeFailure.malformedRedirect) {
            try await OneClickUnsubscribeClient(transport: transport).submitOneClickUnsubscribe(Self.request())
        }
    }

    @Test("A relative Location resolves against the current https URL and stays on it")
    func followsRelativeRedirect() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            request.url?.path == "/u/abc"
                ? HTTPResponse(statusCode: 307, headers: ["Location": "/u/confirmed"])
                : HTTPResponse(statusCode: 200)
        }

        let receipt = try await OneClickUnsubscribeClient(transport: transport)
            .submitOneClickUnsubscribe(Self.request())

        #expect(receipt.wasAccepted)
        #expect(receipt.host == "lists.example")
        #expect(transport.requests.last?.url?.absoluteString == "https://lists.example/u/confirmed")
    }

    @Test("A 3xx the policy does not model is refused rather than interpreted")
    func refusesUnmodelledRedirect() async {
        for status in [300, 305, 306, 399] {
            let transport = RecordingHTTPTransport { _, _ in
                HTTPResponse(statusCode: status, headers: ["Location": "https://elsewhere.example/u"])
            }

            await #expect(throws: UnsubscribeFailure.unsupportedRedirect(statusCode: status)) {
                try await OneClickUnsubscribeClient(transport: transport).submitOneClickUnsubscribe(Self.request())
            }
            #expect(transport.requests(matching: "elsewhere.example").isEmpty)
        }
    }

    @Test("The policy's decisions are a value, not a URLSession default")
    func redirectPolicyIsExplicit() {
        let base = Self.endpoint

        #expect(UnsubscribeRedirectPolicy.decide(statusCode: 200, location: nil, base: base, redirectsSoFar: 0) == .useResponse)
        #expect(UnsubscribeRedirectPolicy.decide(statusCode: 302, location: "https://a.example", base: base, redirectsSoFar: 0) == .stopAtMethodChange)
        #expect(
            UnsubscribeRedirectPolicy.decide(statusCode: 308, location: "https://a.example/u", base: base, redirectsSoFar: 0)
                == .follow(HTTPSUnsubscribeURL(string: "https://a.example/u")!)
        )
        #expect(
            UnsubscribeRedirectPolicy.decide(statusCode: 308, location: "https://a.example/u", base: base, redirectsSoFar: 3)
                == .refuse(.tooManyRedirects(limit: 3))
        )
        #expect(UnsubscribeRedirectPolicy.maximumRedirects == 3)
        #expect(UnsubscribeRedirectPolicy.methodPreservingStatuses == [307, 308])
    }

    // MARK: - Network failure

    @Test("A transport failure is a failure, reported without naming a URL")
    func networkFailure() async {
        let transport = RecordingHTTPTransport { _, _ in throw URLError(.notConnectedToInternet) }

        do {
            _ = try await OneClickUnsubscribeClient(transport: transport).submitOneClickUnsubscribe(Self.request())
            Issue.record("Expected a network failure")
        } catch let failure as UnsubscribeFailure {
            guard case .network(let reason) = failure else {
                Issue.record("Expected a network failure, got \(failure)")
                return
            }
            // A reason a person can read, with no URL and no token in it.
            #expect(reason == "This Mac doesn't seem to be online.")
            #expect(!reason.contains("lists.example"))
        } catch {
            Issue.record("Expected an UnsubscribeFailure, got \(error)")
        }
    }
}

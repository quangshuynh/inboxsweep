import CryptoKit
import Foundation
import Testing
@testable import InboxSweep

@Suite("Gmail OAuth")
struct GmailOAuthClientTests {

    private let configuration = GmailOAuthConfiguration(
        clientID: "1234567890-abcdef.apps.googleusercontent.com"
    )!

    private func client(
        transport: HTTPTransport,
        webAuthenticator: WebAuthenticating = FakeWebAuthenticator.granting()
    ) -> GmailOAuthClient {
        GmailOAuthClient(
            configuration: configuration,
            transport: transport,
            webAuthenticator: webAuthenticator,
            makeState: { "fixed-state" },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func tokenTransport(_ json: String, status: Int = 200) -> RecordingHTTPTransport {
        RecordingHTTPTransport { _, _ in
            HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
        }
    }

    // MARK: - Configuration

    @Test("The callback scheme is the client ID's reverse-DNS form")
    func derivesCallbackScheme() {
        #expect(configuration.callbackScheme == "com.googleusercontent.apps.1234567890-abcdef")
        #expect(configuration.redirectURI == "com.googleusercontent.apps.1234567890-abcdef:/oauth2redirect")
    }

    @Test("A value that is not a Google client ID is rejected", arguments: [
        "", "not-a-client-id", "example.com", ".apps.googleusercontent.com",
    ])
    func rejectsInvalidClientIDs(value: String) {
        #expect(GmailOAuthConfiguration(clientID: value) == nil)
    }

    @Test("An explicit reversed client ID is preferred over the derived one")
    func honoursSuppliedReversedClientID() {
        let configuration = GmailOAuthConfiguration(
            clientID: "1234567890-abcdef.apps.googleusercontent.com",
            reversedClientID: "com.googleusercontent.apps.custom"
        )
        #expect(configuration?.callbackScheme == "com.googleusercontent.apps.custom")
    }

    // MARK: - Authorization request

    @Test("The authorization request asks for exactly one scope, with PKCE and no secret")
    func buildsAuthorizationURL() throws {
        let challenge = PKCEChallenge()
        let url = client(transport: tokenTransport("{}")).makeAuthorizationURL(challenge: challenge, state: "fixed-state")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(url.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth"))
        #expect(value("client_id") == configuration.clientID)
        #expect(value("redirect_uri") == configuration.redirectURI)
        #expect(value("response_type") == "code")
        // Both scopes, in one authorization. The user sees one consent screen naming what the
        // app will read and what it will be able to change, rather than being asked again later.
        #expect(value("scope") == GmailScope.requestedScopeParameter)
        #expect(value("scope")?.contains(GmailScope.metadata) == true)
        #expect(value("scope")?.contains(GmailScope.modify) == true)
        #expect(value("code_challenge") == challenge.challenge)
        #expect(value("code_challenge_method") == "S256")
        #expect(value("state") == "fixed-state")
        // A public desktop client has no secret to send, and must never appear to have one.
        #expect(!items.contains { $0.name == "client_secret" })
    }

    @Test("The PKCE challenge is the SHA-256 of the verifier, base64url encoded")
    func generatesValidPKCEPair() {
        let challenge = PKCEChallenge()
        let expected = PKCEChallenge.base64URLEncoded(Data(SHA256.hash(data: Data(challenge.verifier.utf8))))

        #expect(challenge.challenge == expected)
        #expect(challenge.method == "S256")
        #expect(challenge.verifier.count >= 43)
        #expect(!challenge.verifier.contains("="))
        #expect(!challenge.verifier.contains("+"))
        #expect(!challenge.verifier.contains("/"))
    }

    @Test("Two challenges are never the same")
    func generatesUniqueChallenges() {
        #expect(PKCEChallenge().verifier != PKCEChallenge().verifier)
    }

    // MARK: - Redirect handling

    @Test("A redirect whose state does not match the request is rejected")
    func rejectsMismatchedState() async {
        let oauth = client(transport: tokenTransport(GmailFixtures.tokenJSON()),
                           webAuthenticator: FakeWebAuthenticator.replayingForeignState())

        await #expect(throws: MailProviderError.self) { _ = try await oauth.authorize() }
    }

    @Test("A denied consent is explained in terms of what the user did")
    func explainsDeniedConsent() async throws {
        let oauth = client(transport: tokenTransport(GmailFixtures.tokenJSON()),
                           webAuthenticator: FakeWebAuthenticator.denying())

        let error = await #expect(throws: MailProviderError.self) { _ = try await oauth.authorize() }
        let reason = try #require(error?.failureReason)
        #expect(reason.contains("declined"))
    }

    @Test("Closing the sign-in window reads as cancellation, not failure")
    func propagatesCancellation() async {
        let oauth = client(transport: tokenTransport(GmailFixtures.tokenJSON()),
                           webAuthenticator: FakeWebAuthenticator.cancelling())

        await #expect(throws: MailProviderError.cancelled) { _ = try await oauth.authorize() }
    }

    @Test("A redirect with no code at all is a failure, not an empty success")
    func rejectsMissingCode() {
        let oauth = client(transport: tokenTransport("{}"))
        let url = URL(string: "com.googleusercontent.apps.x:/oauth2redirect?state=fixed-state")!

        #expect(throws: MailProviderError.self) {
            _ = try oauth.authorizationCode(from: url, expectedState: "fixed-state")
        }
    }

    // MARK: - Callbacks that arrive off the main queue
    //
    // `ASWebAuthenticationSession` calls its completion handler from its own XPC queue, not
    // from the main actor. These run the whole authorize/exchange flow with the redirect
    // delivered that way, which is the path that used to trap in libdispatch.

    @MainActor
    @Test("A redirect delivered from a background queue completes the whole sign-in")
    func exchangesCodeDeliveredOffTheMainQueue() async throws {
        let transport = tokenTransport(GmailFixtures.tokenJSON(expiresIn: 1_800))
        let oauth = client(transport: transport, webAuthenticator: FakeWebAuthenticator.granting().offTheMainQueue)

        let grant = try await oauth.authorize()

        #expect(grant.accessToken.value == "access-token")
        #expect(grant.refreshToken == "refresh-token")
        // The `state` check still ran, so the redirect really did survive the hop intact.
        let body = String(decoding: try #require(transport.requests.last?.httpBody), as: UTF8.self)
        #expect(body.contains("code=auth-code"))
        MainActor.assertIsolated()
    }

    @MainActor
    @Test("Cancellation delivered from a background queue is still cancellation")
    func propagatesCancellationFromOffTheMainQueue() async {
        let oauth = client(transport: tokenTransport(GmailFixtures.tokenJSON()),
                           webAuthenticator: FakeWebAuthenticator.cancelling().offTheMainQueue)

        await #expect(throws: MailProviderError.cancelled) { _ = try await oauth.authorize() }
    }

    @MainActor
    @Test("An OAuth error delivered from a background queue still explains what happened")
    func propagatesDenialFromOffTheMainQueue() async throws {
        let oauth = client(transport: tokenTransport(GmailFixtures.tokenJSON()),
                           webAuthenticator: FakeWebAuthenticator.denying().offTheMainQueue)

        let error = await #expect(throws: MailProviderError.self) { _ = try await oauth.authorize() }
        #expect(try #require(error?.failureReason).contains("declined"))
    }

    @MainActor
    @Test("A foreign `state` delivered from a background queue is still rejected")
    func rejectsForeignStateFromOffTheMainQueue() async {
        let oauth = client(transport: tokenTransport(GmailFixtures.tokenJSON()),
                           webAuthenticator: FakeWebAuthenticator.replayingForeignState().offTheMainQueue)

        await #expect(throws: MailProviderError.self) { _ = try await oauth.authorize() }
    }

    // MARK: - Token exchange

    @Test("A successful exchange returns an access token, its expiry, and the refresh token")
    func exchangesCodeForTokens() async throws {
        let transport = tokenTransport(GmailFixtures.tokenJSON(expiresIn: 1_800))
        let grant = try await client(transport: transport).authorize()

        #expect(grant.accessToken.value == "access-token")
        #expect(grant.refreshToken == "refresh-token")
        #expect(grant.accessToken.expiresAt == Date(timeIntervalSince1970: 1_700_001_800))
        #expect(grant.accessToken.grantedScopes == [GmailScope.metadata])
    }

    @Test("The code exchange sends the PKCE verifier and no client secret")
    func sendsVerifierNotSecret() async throws {
        let transport = tokenTransport(GmailFixtures.tokenJSON())
        _ = try await client(transport: transport).authorize()

        let request = try #require(transport.requests.last)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)

        #expect(request.httpMethod == "POST")
        #expect(body.contains("code_verifier="))
        #expect(body.contains("grant_type=authorization_code"))
        #expect(!body.contains("client_secret"))
    }

    @Test("A refresh token that Google has invalidated asks for a fresh sign-in")
    func mapsInvalidGrant() async {
        let transport = tokenTransport(GmailFixtures.oauthErrorJSON("invalid_grant"), status: 400)

        await #expect(throws: MailProviderError.authorizationExpired) {
            _ = try await client(transport: transport).refresh(using: "stale-refresh-token")
        }
    }

    @Test("A rejected OAuth client points at the setup documentation")
    func mapsInvalidClient() async throws {
        let transport = tokenTransport(GmailFixtures.oauthErrorJSON("invalid_client"), status: 401)

        let error = await #expect(throws: MailProviderError.self) {
            _ = try await client(transport: transport).refresh(using: "refresh-token")
        }
        #expect(try #require(error?.failureReason).contains("OAuthSetup"))
    }

    @Test("An unreadable token response is reported as malformed, not as a denial")
    func mapsMalformedTokenResponse() async {
        let transport = tokenTransport("not json at all")

        await #expect(throws: MailProviderError.malformedResponse(
            reason: "Google's sign-in response couldn't be read."
        )) {
            _ = try await client(transport: transport).refresh(using: "refresh-token")
        }
    }

    @Test("Revoking posts the token to Google's revocation endpoint")
    func revokesGrant() async throws {
        let transport = tokenTransport("{}")
        try await client(transport: transport).revoke(token: "access-token")

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(request.httpMethod == "POST")
    }
}

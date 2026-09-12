import Foundation

/// Drives Google's OAuth 2.0 authorization-code flow with PKCE.
///
/// Everything token-shaped stays inside this type and the actor that owns it. Errors raised
/// here carry only Google's `error` code and our own wording, never the response body, an
/// authorization code, or a token.
nonisolated struct GmailOAuthClient: Sendable {

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    private let configuration: GmailOAuthConfiguration
    private let transport: HTTPTransport
    private let webAuthenticator: WebAuthenticating
    private let makeChallenge: @Sendable () -> PKCEChallenge
    private let makeState: @Sendable () -> String
    private let now: @Sendable () -> Date

    init(
        configuration: GmailOAuthConfiguration,
        transport: HTTPTransport,
        webAuthenticator: WebAuthenticating,
        makeChallenge: @escaping @Sendable () -> PKCEChallenge = { PKCEChallenge() },
        makeState: @escaping @Sendable () -> String = {
            PKCEChallenge.base64URLEncoded(Data(PKCEChallenge.secureRandomBytes(count: 16)))
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.webAuthenticator = webAuthenticator
        self.makeChallenge = makeChallenge
        self.makeState = makeState
        self.now = now
    }

    /// The result of a completed interactive sign-in.
    struct Grant: Sendable, Equatable {
        let accessToken: GmailAccessToken
        let refreshToken: String?
    }

    // MARK: - Interactive sign-in

    /// Presents Google's consent screen and exchanges the resulting code for tokens.
    func authorize() async throws -> Grant {
        let challenge = makeChallenge()
        let state = makeState()
        let authorizationURL = makeAuthorizationURL(challenge: challenge, state: state)

        let callbackURL = try await webAuthenticator.authenticate(
            url: authorizationURL,
            callbackScheme: configuration.callbackScheme
        )

        let code = try authorizationCode(from: callbackURL, expectedState: state)
        return try await exchange(code: code, verifier: challenge.verifier)
    }

    func makeAuthorizationURL(challenge: PKCEChallenge, state: String) -> URL {
        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GmailScope.requestedScopeParameter),
            URLQueryItem(name: "code_challenge", value: challenge.challenge),
            URLQueryItem(name: "code_challenge_method", value: challenge.method),
            URLQueryItem(name: "state", value: state),
            // Ask for a refresh token so the user is not sent back to Google every launch.
            URLQueryItem(name: "access_type", value: "offline"),
        ]
        return components.url!
    }

    /// Validates the redirect and pulls the authorization code out of it.
    ///
    /// The `state` check is what prevents a redirect belonging to some other authorization
    /// attempt from being accepted as if it were ours.
    func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw MailProviderError.authenticationFailed(reason: "Google's response couldn't be read.")
        }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        if let error = value("error") {
            throw MailProviderError.authenticationFailed(reason: Self.describe(oauthError: error))
        }

        guard value("state") == expectedState else {
            throw MailProviderError.authenticationFailed(
                reason: "Google's response didn't match the sign-in request InboxSweep started."
            )
        }

        guard let code = value("code"), !code.isEmpty else {
            throw MailProviderError.authenticationFailed(reason: "Google didn't return an authorization code.")
        }

        return code
    }

    // MARK: - Token endpoint

    private func exchange(code: String, verifier: String) async throws -> Grant {
        let response: TokenResponse = try await postForm([
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": configuration.redirectURI,
        ])

        return Grant(accessToken: makeAccessToken(from: response), refreshToken: response.refreshToken)
    }

    /// Exchanges a stored refresh token for a fresh access token.
    func refresh(using refreshToken: String) async throws -> GmailAccessToken {
        let response: TokenResponse = try await postForm([
            "client_id": configuration.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        return makeAccessToken(from: response)
    }

    /// Asks Google to invalidate the grant. Best-effort: failures are the caller's to ignore.
    ///
    /// This is the only network call the app makes that changes anything, and what it changes
    /// is InboxSweep's own access, not the mailbox.
    func revoke(token: String) async throws {
        var request = URLRequest(url: Self.revocationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(["token": token])
        _ = try await transport.send(request)
    }

    private func makeAccessToken(from response: TokenResponse) -> GmailAccessToken {
        GmailAccessToken(
            value: response.accessToken,
            expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn ?? 3600)),
            grantedScopes: response.scope?.split(separator: " ").map(String.init) ?? GmailScope.requested
        )
    }

    private func postForm(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw MailProviderError.wrapping(error)
        }

        guard response.isSuccess else {
            throw Self.tokenError(from: response)
        }

        do {
            return try JSONDecoder().decode(TokenResponse.self, from: response.body)
        } catch {
            throw MailProviderError.malformedResponse(reason: "Google's sign-in response couldn't be read.")
        }
    }

    /// Maps a token-endpoint failure without echoing the response body back to the user.
    private static func tokenError(from response: HTTPResponse) -> MailProviderError {
        let code = (try? JSONDecoder().decode(TokenErrorResponse.self, from: response.body))?.error

        switch code {
        case "invalid_grant":
            return .authorizationExpired
        case "access_denied":
            return .authenticationFailed(reason: "Access was declined.")
        case "invalid_scope":
            return .insufficientPermissions(
                reason: "Google rejected the permissions InboxSweep asked for."
            )
        default:
            return .authenticationFailed(reason: describe(oauthError: code ?? "unknown_error"))
        }
    }

    private static func describe(oauthError code: String) -> String {
        switch code {
        case "access_denied":
            "You declined the permission request, so InboxSweep wasn't connected."
        case "invalid_client", "unauthorized_client":
            "Google rejected this app's OAuth client. Check the client ID in Docs/OAuthSetup.md."
        case "invalid_scope":
            "Google rejected the permissions InboxSweep asked for."
        default:
            "Google reported \"\(code)\"."
        }
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        // Sorted so the request body is deterministic and therefore assertable in tests.
        components.queryItems = fields.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    // MARK: - Wire types

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int?
        let refreshToken: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
        }
    }

    private struct TokenErrorResponse: Decodable {
        let error: String?
    }
}

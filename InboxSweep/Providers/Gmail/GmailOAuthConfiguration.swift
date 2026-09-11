import Foundation

/// The OAuth client identity InboxSweep signs in with.
///
/// InboxSweep uses a Google OAuth client of the *iOS/macOS* type, which has **no client
/// secret**: authorization is protected by PKCE instead. That is a deliberate choice: a
/// desktop app cannot keep a secret from the person running it, and having no secret means
/// there is nothing secret-shaped that could be committed to this repository by accident.
///
/// The client ID itself is not a credential, but it is still account-specific, so it is
/// supplied at runtime rather than hard-coded. See `Docs/OAuthSetup.md`.
nonisolated struct GmailOAuthConfiguration: Hashable, Sendable {

    /// Environment variable checked first, which is the convenient path when running from Xcode.
    static let clientIDEnvironmentKey = "INBOXSWEEP_GOOGLE_CLIENT_ID"

    /// Resource name of the property list downloaded from the Google Cloud console.
    static let propertyListName = "GoogleOAuthClient"

    /// e.g. `1234567890-abcdef.apps.googleusercontent.com`
    let clientID: String

    /// The custom URL scheme Google will redirect back to: the client ID's reverse-DNS form.
    let callbackScheme: String

    /// The full redirect URI sent in the authorization request.
    var redirectURI: String { "\(callbackScheme):/oauth2redirect" }

    init?(clientID: String, reversedClientID: String? = nil) {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(Self.clientIDSuffix), trimmed.count > Self.clientIDSuffix.count else {
            return nil
        }
        self.clientID = trimmed
        self.callbackScheme = reversedClientID?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? Self.reversedClientID(for: trimmed)
    }

    private static let clientIDSuffix = ".apps.googleusercontent.com"

    /// `1234-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.1234-abc`
    private static func reversedClientID(for clientID: String) -> String {
        let identifier = clientID.dropLast(clientIDSuffix.count)
        return "com.googleusercontent.apps.\(identifier)"
    }
}

nonisolated extension GmailOAuthConfiguration {

    /// Loads configuration from the environment, then from a bundled property list.
    ///
    /// Returns `nil` when the app has not been configured; callers surface that as
    /// ``MailProviderError/notConfigured(reason:)`` rather than failing at launch, so the app
    /// still runs, still explains itself, and still works against sample data.
    static func load(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GmailOAuthConfiguration? {
        if let clientID = environment[clientIDEnvironmentKey],
           let configuration = GmailOAuthConfiguration(clientID: clientID) {
            return configuration
        }

        guard let url = bundle.url(forResource: propertyListName, withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let clientID = plist["CLIENT_ID"] as? String
        else { return nil }

        return GmailOAuthConfiguration(
            clientID: clientID,
            reversedClientID: plist["REVERSED_CLIENT_ID"] as? String
        )
    }

    /// Explains, in the UI, what is missing and roughly how to fix it.
    static let missingConfigurationReason = """
        No Google OAuth client ID was found. Add one by following Docs/OAuthSetup.md, either \
        set the \(clientIDEnvironmentKey) environment variable or drop your \
        \(propertyListName).plist into InboxSweep/Config/.
        """
}

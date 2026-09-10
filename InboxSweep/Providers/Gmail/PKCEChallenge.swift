import CryptoKit
import Foundation

/// A PKCE (RFC 7636) verifier/challenge pair.
///
/// PKCE is what makes a client-secret-free desktop OAuth client safe: the authorization code
/// Google returns is worthless to anyone who intercepts it without the verifier, which never
/// leaves this process.
nonisolated struct PKCEChallenge: Sendable, Equatable {
    let verifier: String
    let challenge: String
    let method = "S256"

    /// Generates a fresh pair from cryptographically secure random bytes.
    init(randomBytes: [UInt8] = PKCEChallenge.secureRandomBytes(count: 32)) {
        let verifier = Self.base64URLEncoded(Data(randomBytes))
        self.verifier = verifier
        self.challenge = Self.base64URLEncoded(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func secureRandomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "The system random number generator is unavailable.")
        return bytes
    }

    /// Base64 with the URL-safe alphabet and no padding, as PKCE requires.
    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

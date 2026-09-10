import Foundation

/// A short-lived access token and what it is allowed to do.
///
/// Access tokens never leave the Gmail adapter: the provider boundary has no API that returns
/// one, and this type is not visible above it.
nonisolated struct GmailAccessToken: Sendable, Equatable {
    let value: String
    let expiresAt: Date
    let grantedScopes: [String]

    /// Treats a token as expired slightly early, so a request is not sent with a token that
    /// expires while it is in flight.
    func isExpired(asOf now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }
}

/// The long-lived state worth keeping between launches.
///
/// Only the refresh token and the identifying details are persisted. Access tokens are not
/// stored, because they expire in about an hour and are cheap to re-obtain — keeping them on
/// disk would add exposure for no benefit.
nonisolated struct GmailStoredCredentials: Sendable, Equatable, Codable {
    let refreshToken: String
    let grantedScopes: [String]
    let accountEmailAddress: String

    /// Whether the stored grant still covers everything the app needs to read.
    var coversRequestedScopes: Bool {
        GmailScope.requested.allSatisfy(grantedScopes.contains)
    }
}

/// Persistence for ``GmailStoredCredentials``.
nonisolated protocol GmailCredentialStoring: Sendable {
    func load() throws -> GmailStoredCredentials?
    func save(_ credentials: GmailStoredCredentials) throws
    func clear() throws
}

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

    /// Whether the stored grant still covers everything the app needs to *read*.
    ///
    /// Deliberately not "covers everything requested". Since the archive permission was added,
    /// a grant stored by an earlier version covers reading and not archiving — and that grant
    /// is perfectly good. Discarding it would sign out every existing user over a capability
    /// they have not asked to use, so the two questions are asked separately and only this one
    /// decides whether a stored credential is usable.
    var coversReadScopes: Bool {
        GmailScope.coversReading(grantedScopes)
    }

    /// Whether the stored grant covers archiving.
    ///
    /// `false` for every credential written before the archive permission existed, which is
    /// the state the upgrade flow is there to resolve.
    var coversArchiveScopes: Bool {
        GmailScope.coversArchiving(grantedScopes)
    }

    /// The same credential with a new record of what was granted.
    ///
    /// Used after a permission upgrade that returned no new refresh token — Google omits one
    /// when the client already holds a valid grant — so the scope record is brought up to date
    /// without throwing away the refresh token that still works.
    func replacingGrantedScopes(_ scopes: [String]) -> GmailStoredCredentials {
        GmailStoredCredentials(
            refreshToken: refreshToken,
            grantedScopes: scopes,
            accountEmailAddress: accountEmailAddress
        )
    }
}

/// Persistence for ``GmailStoredCredentials``.
nonisolated protocol GmailCredentialStoring: Sendable {
    func load() throws -> GmailStoredCredentials?
    func save(_ credentials: GmailStoredCredentials) throws
    func clear() throws
}

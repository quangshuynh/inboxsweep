import Foundation

/// What actually happened when the user disconnected.
///
/// Disconnecting used to return nothing, and its two failure modes were both swallowed by
/// `try?`: a revoke the provider refused, and — the one that matters — a stored credential the
/// Keychain would not delete. The second is a refresh token still sitting on the Mac after the
/// user was shown a signed-out window, which is precisely the sort of thing an app must not
/// discover quietly.
///
/// Signing out still always succeeds from the user's point of view: every case here leaves the
/// app signed out and the window cleared. The difference is that two of them say so out loud.
///
/// Every string is fixed English or an `OSStatus`. Nothing derived from a token reaches it.
nonisolated enum MailDisconnectOutcome: Equatable, Sendable {

    /// The stored credential is gone, and the provider was told to drop the grant — or there
    /// was no grant to drop.
    case complete

    /// The credential is gone from this Mac, and the provider could not be told to drop the
    /// grant. It stays live on the account until the user withdraws it themselves.
    case grantNotRevoked

    /// The stored credential could not be removed. `reason` is a short, secret-free sentence,
    /// at most naming a Keychain status.
    ///
    /// Ranked above ``grantNotRevoked``: a credential still on disk is worse news than a grant
    /// still on the account, and only one notice is shown.
    case storedCredentialRetained(reason: String)

    /// Whether anything went wrong that the user should hear about.
    var isClean: Bool { self == .complete }
}

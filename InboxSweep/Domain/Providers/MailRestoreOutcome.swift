import Foundation

/// What happened when the app tried to re-establish a previously authorized connection.
///
/// Three outcomes, deliberately not two. Before this interval a restore either produced an
/// account or produced nothing, and "nothing" covered both *there was never a stored sign-in*
/// and *there is one and we could not read it*. Those look identical on screen: a signed-out
/// window, and they need completely different responses: the first is an ordinary first
/// launch, the second is a fault the user should hear about.
nonisolated enum MailRestoreOutcome: Equatable, Sendable {

    /// Nothing was stored. The ordinary first-launch case, and not a failure.
    case noStoredCredentials

    /// A stored authorization was found and still works.
    case restored(MailAccount)

    /// Something was stored, and it could not be used. ``MailRestoreFailure`` says why.
    case unusable(MailRestoreFailure)

    var account: MailAccount? {
        if case .restored(let account) = self { return account }
        return nil
    }
}

/// Why a stored authorization could not be turned back into a connection.
///
/// Each case is distinguished because the app does something different about it: two of them
/// simply ask the user to connect again, one warns that the Keychain is refusing, and one is a
/// transient outage where the right move is to retry rather than re-authorize.
nonisolated enum MailRestoreFailure: Equatable, Sendable {

    /// The credential store has an item but would not hand it over: a Keychain access or
    /// authorization failure rather than an absence.
    case credentialStoreUnreadable(reason: String)

    /// Something was stored but is not a credential this build can read. It has been discarded.
    case storedCredentialsMalformed

    /// The stored grant was rejected by the provider: expired, or revoked from the account.
    case authorizationRevoked

    /// The stored grant no longer covers the scopes the app needs, so it was discarded.
    case scopesNoLongerSufficient

    /// The provider could not be reached, or failed for a reason unrelated to authorization.
    /// The stored credentials are untouched and retrying is the right move.
    case providerUnavailable(MailProviderError)

    /// Whether the way out is to sign in again, as opposed to trying again later.
    var requiresReauthentication: Bool {
        switch self {
        case .authorizationRevoked, .scopesNoLongerSufficient, .storedCredentialsMalformed: true
        case .credentialStoreUnreadable: true
        case .providerUnavailable(let error): error.requiresReauthentication
        }
    }

    /// The error the UI shows. Every string here is fixed English or an `OSStatus`; nothing
    /// derived from a token, a response body, or mailbox content reaches it.
    var providerError: MailProviderError {
        switch self {
        case .credentialStoreUnreadable(let reason):
            .authenticationFailed(reason: reason)
        case .storedCredentialsMalformed:
            .authenticationFailed(
                reason: "The saved sign-in on this Mac couldn't be read, so it was discarded. Connecting again will replace it."
            )
        case .authorizationRevoked, .scopesNoLongerSufficient:
            .authorizationExpired
        case .providerUnavailable(let error):
            error
        }
    }
}

/// Whether the provider managed to remember an authorization for the next launch.
///
/// Exists because the original credential-restore defect was a *write* that failed silently:
/// sign-in succeeded, the refresh token was never stored, and the app looked signed out on
/// every relaunch with nothing anywhere saying why. A failure to persist is not worth failing a
/// sign-in over (the session still works) but it is absolutely worth saying out loud.
nonisolated enum StoredAuthorizationState: Equatable, Sendable {

    /// The authorization was written and should survive a relaunch.
    case persisted

    /// It was not. `reason` is a short, secret-free sentence.
    case notPersisted(reason: String)

    /// Nothing has been signed in yet, or this provider does not persist anything.
    case unknown

    var isPersisted: Bool { self == .persisted }

    /// The warning to show, or `nil` when there is nothing to warn about.
    var warning: String? {
        guard case .notPersisted(let reason) = self else { return nil }
        return reason
    }
}

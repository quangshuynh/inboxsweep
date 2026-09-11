import Foundation

/// Something the user should know that is not worth an error screen.
///
/// Two situations need this, and both were previously invisible:
///
/// - A stored sign-in could not be restored. The app lands on the signed-out screen either
///   way, so without a notice a Keychain refusal and an ordinary first launch are the same
///   picture — which is how a credential-persistence bug survived a whole interval.
/// - A sign-in succeeded but could not be *saved*. The session works, so nothing fails; the
///   user simply finds themselves signed out next launch with no explanation.
///
/// Every message here is fixed English, optionally carrying an `OSStatus`. Nothing derived
/// from a token, a refresh token, a response body, or mailbox content reaches this type.
nonisolated struct SessionNotice: Equatable, Sendable, Identifiable {

    let symbolName: String
    let title: String
    let message: String

    var id: String { title + message }

    // MARK: - Restore

    /// The stored authorization is gone or no longer valid. The way out is to connect again.
    static let authorizationEnded = SessionNotice(
        symbolName: "lock.rotation",
        title: "Your previous sign-in is no longer valid",
        message: """
            The authorization InboxSweep had saved has expired or was withdrawn from your Google \
            Account. Connect again to carry on. Your mailbox was not changed.
            """
    )

    /// The granted scopes no longer cover what the app reads.
    static let scopesChanged = SessionNotice(
        symbolName: "lock.rotation",
        title: "InboxSweep needs to ask for its permission again",
        message: """
            The saved sign-in doesn't cover the permission this version needs to read your mail, \
            so it was discarded. Connecting again will request it.
            """
    )

    /// The credential store refused, or held something unreadable.
    ///
    /// `reason` comes from ``CredentialStoreError/diagnosticDescription`` and is a sentence
    /// plus, at most, a Keychain status code.
    static func credentialStoreUnreadable(reason: String) -> SessionNotice {
        SessionNotice(
            symbolName: "key.slash",
            title: "InboxSweep couldn't read your saved sign-in",
            message: """
                \(reason) This is not the same as being signed out, so it is worth knowing about. \
                Connecting again will store a fresh sign-in.
                """
        )
    }

    // MARK: - Persistence

    /// A sign-in that worked but was not saved.
    static func notPersisted(reason: String) -> SessionNotice {
        SessionNotice(
            symbolName: "externaldrive.badge.exclamationmark",
            title: "This sign-in won't survive a relaunch",
            message: reason
        )
    }

    // MARK: - Archiving

    /// The user was asked for the archive permission and did not grant it.
    ///
    /// Not an error screen, because nothing failed: the read-only session they already had is
    /// exactly as it was, and every part of the app except the Archive button still works. The
    /// notice exists so the button staying unavailable is explained rather than mysterious.
    static let archivePermissionDeclined = SessionNotice(
        symbolName: "hand.raised",
        title: "InboxSweep still can't archive",
        message: """
            The extra Gmail permission wasn't granted, so the Archive action stays unavailable.             Everything else works as before, your mailbox was not changed, and you can grant it             later from the message review screen.
            """
    )

    // MARK: - Disconnect

    /// The stored credential survived a sign-out.
    ///
    /// The most serious thing this type says. The user asked to be disconnected, the window
    /// says they are, and a refresh token is still on the Mac — so the notice tells them where
    /// to go and remove it themselves rather than leaving them to assume it is gone.
    static func credentialNotRemoved(reason: String) -> SessionNotice {
        SessionNotice(
            symbolName: "key.slash",
            title: "InboxSweep couldn't remove your saved sign-in",
            message: """
                \(reason) InboxSweep is signed out and your mailbox was not changed, but the saved                 sign-in is still on this Mac. You can delete the "InboxSweep — Gmail sign-in" item                 in Keychain Access, and withdraw the access at myaccount.google.com.
                """
        )
    }

    /// Signing out worked locally; Google was not told.
    static let grantNotRevoked = SessionNotice(
        symbolName: "person.badge.shield.exclamationmark",
        title: "InboxSweep signed out, but Google wasn't told",
        message: """
            The saved sign-in has been removed from this Mac. InboxSweep couldn't reach Google to             withdraw the access itself, so the permission is still listed on your account until you             remove it at myaccount.google.com. Your mailbox was not changed.
            """
    )

    /// The notice for a disconnect, or `nil` when it went cleanly.
    static func forDisconnectOutcome(_ outcome: MailDisconnectOutcome) -> SessionNotice? {
        switch outcome {
        case .complete: nil
        case .grantNotRevoked: grantNotRevoked
        case .storedCredentialRetained(let reason): credentialNotRemoved(reason: reason)
        }
    }

    // MARK: - Mapping

    /// The notice for a restore failure, or `nil` when the failure deserves an error screen
    /// instead — a provider outage is something to retry, not something to re-authorize.
    static func forRestoreFailure(_ failure: MailRestoreFailure) -> SessionNotice? {
        switch failure {
        case .authorizationRevoked: authorizationEnded
        case .scopesNoLongerSufficient: scopesChanged
        case .storedCredentialsMalformed, .credentialStoreUnreadable:
            credentialStoreUnreadable(reason: failure.providerError.failureReason ?? "")
        case .providerUnavailable: nil
        }
    }
}

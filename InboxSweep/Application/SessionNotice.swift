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
            The saved sign-in doesn't cover the read-only permission this version asks for, so it \
            was discarded. Connecting again will request it.
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

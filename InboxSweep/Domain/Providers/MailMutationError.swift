import Foundation

/// The ways changing one message can fail, kept separate from ``MailProviderError``.
///
/// A separate type because the recoveries are different. A failed *read* is almost always
/// "try again" or "connect again"; a failed *write* has to answer a question a read never
/// raises — did anything happen to the mailbox? Every case below is unambiguous about that,
/// and ``changedTheMailbox`` says so in code rather than leaving it to the wording.
///
/// Associated values are short, already-sanitized strings. No case carries a token, an
/// authorization code, a raw Gmail response body, a subject, or an address — these are shown
/// on screen.
nonisolated enum MailMutationError: Error, Equatable, Sendable {

    /// This provider has no way to change a mailbox. Re-authorizing would not help.
    case notSupported

    /// The grant in hand does not include the archive permission.
    case permissionRequired

    /// The user was asked for the archive permission and did not grant it.
    case permissionDeclined

    /// The authorization has expired or been withdrawn. Nothing was changed.
    case authorizationExpired

    /// The authenticated account is no longer the one this message was loaded from.
    ///
    /// Refused rather than attempted: a request built against one mailbox must never be sent
    /// to another.
    case accountChanged

    /// The message is not part of the window currently on screen, so there is nothing to act
    /// on and nothing to reconcile afterwards.
    case messageNotInLoadedWindow

    /// The provider no longer has this message — it was moved or deleted elsewhere.
    case messageNoLongerAvailable

    /// The provider is throttling this account. Waiting and repeating the action is the fix.
    case rateLimited

    /// The request never reached the provider, or the reply never came back.
    case network(reason: String)

    /// The provider was reached and refused. `reason` is the app's own wording.
    case rejectedByProvider(reason: String)

    /// The action was abandoned before the request went out. Nothing was changed.
    case cancelled

    /// Whether this failure could have left the mailbox changed.
    ///
    /// Every case is `false` today, and that is the point: the app only reports a mutation
    /// error when it knows the mailbox was not touched. A provider response that leaves it
    /// genuinely unknown is reported as ``rejectedByProvider`` with wording that says to
    /// refresh — see ``recoverySuggestion``.
    var changedTheMailbox: Bool { false }

    /// Whether repeating the same action could plausibly succeed.
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .network, .rejectedByProvider, .cancelled: true
        case .notSupported, .permissionRequired, .permissionDeclined, .authorizationExpired,
             .accountChanged, .messageNotInLoadedWindow, .messageNoLongerAvailable: false
        }
    }

    /// Whether the way out is to ask the user for the archive permission.
    var isResolvedByGrantingPermission: Bool {
        switch self {
        case .permissionRequired, .permissionDeclined: true
        default: false
        }
    }

    /// Whether the user has to look at a fresh window before trying again.
    var requiresReview: Bool {
        switch self {
        case .accountChanged, .messageNotInLoadedWindow, .messageNoLongerAvailable: true
        default: false
        }
    }
}

nonisolated extension MailMutationError: LocalizedError {

    var errorDescription: String? {
        switch self {
        case .notSupported: "This mailbox can't be changed"
        case .permissionRequired: "InboxSweep needs one more Gmail permission"
        case .permissionDeclined: "The archive permission wasn't granted"
        case .authorizationExpired: "InboxSweep needs permission again"
        case .accountChanged: "The connected account changed"
        case .messageNotInLoadedWindow: "That message isn't in the loaded window any more"
        case .messageNoLongerAvailable: "Gmail no longer has that message"
        case .rateLimited: "Gmail is busy with this account"
        case .network: "Couldn't reach Gmail"
        case .rejectedByProvider: "Gmail refused the change"
        case .cancelled: "Archiving was cancelled"
        }
    }

    var failureReason: String? {
        switch self {
        case .notSupported:
            "You're looking at the sample mailbox, which isn't a real Gmail account. Nothing was changed."
        case .permissionRequired:
            """
            The permission InboxSweep was given only lets it read your mail. Archiving a message \
            needs permission to change which labels a message carries. Nothing was changed.
            """
        case .permissionDeclined:
            "Without that permission InboxSweep can still read and suggest, but it can't archive. Nothing was changed."
        case .authorizationExpired:
            "The authorization is no longer valid — it expired, or it was withdrawn from your Google Account. Nothing was changed."
        case .accountChanged:
            """
            The message was chosen while a different Gmail account was connected, so InboxSweep \
            refused to act on it. Nothing was changed.
            """
        case .messageNotInLoadedWindow:
            "The window was reloaded since you chose it, so InboxSweep can't be sure it's still the same message. Nothing was changed."
        case .messageNoLongerAvailable:
            "It was probably deleted or moved somewhere else. Nothing was changed."
        case .rateLimited:
            "Gmail is rate-limiting this account, so it declined the request for now. Nothing was changed."
        case .network(let reason):
            "\(reason) Nothing was changed."
        case .rejectedByProvider(let reason):
            "\(reason) Nothing was changed."
        case .cancelled:
            "The request was abandoned before it reached Gmail. Nothing was changed."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notSupported: "Connect a real Gmail account to archive messages."
        case .permissionRequired, .permissionDeclined: "Grant the extra permission when you're ready, then try again."
        case .authorizationExpired: "Connect your account again to continue."
        case .accountChanged, .messageNotInLoadedWindow: "Reload, open the sender again, and pick the message."
        case .messageNoLongerAvailable: "Reload to see what's actually in your inbox now."
        case .rateLimited: "Wait a moment and try again."
        case .network: "Check your internet connection, then reload to confirm what Gmail has before trying again."
        case .rejectedByProvider: "Reload to confirm what Gmail has, then try again."
        case .cancelled: "Choose the message again whenever you're ready."
        }
    }
}

nonisolated extension MailMutationError {

    /// Maps an arbitrary failure onto the closest case.
    ///
    /// Read failures arrive here as ``MailProviderError`` because the access token, the
    /// transport, and the status-code mapping are shared with the read path. The translation is
    /// deliberately narrow: anything not recognised becomes ``rejectedByProvider`` with the
    /// app's own wording, so nothing from Gmail's response body can reach the screen by
    /// default.
    static func wrapping(_ error: Error) -> MailMutationError {
        if let mutationError = error as? MailMutationError { return mutationError }
        if error is CancellationError { return .cancelled }

        if let providerError = error as? MailProviderError {
            switch providerError {
            case .authorizationExpired:
                return .authorizationExpired
            case .insufficientPermissions:
                return .permissionRequired
            case .network(let reason):
                return .network(reason: reason)
            case .cancelled:
                return .cancelled
            case .providerFailure(let statusCode, _):
                switch statusCode {
                case 404: return .messageNoLongerAvailable
                case 403, 429: return .rateLimited
                default: return .rejectedByProvider(reason: "Gmail returned an error (status \(statusCode)).")
                }
            case .malformedResponse:
                return .rejectedByProvider(reason: "Gmail's reply didn't match what InboxSweep expects.")
            case .notConfigured(let reason), .authenticationFailed(let reason):
                return .rejectedByProvider(reason: reason)
            }
        }

        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return .cancelled }
            return .network(reason: urlError.localizedDescription)
        }

        return .rejectedByProvider(reason: "An unexpected error occurred.")
    }
}

import Foundation

/// The failures the app can meaningfully distinguish and explain.
///
/// Adapters are responsible for translating provider-specific failures into these cases.
/// Associated values are short, already-sanitized strings: adapters must never place a token,
/// an authorization code, a raw response body, or mailbox content into one, because these
/// values are shown in the UI.
nonisolated enum MailProviderError: Error, Equatable, Sendable {

    /// The app has no OAuth client configuration, so sign-in cannot be attempted.
    case notConfigured(reason: String)

    /// Sign-in did not complete: the user cancelled it, or the provider rejected it.
    case authenticationFailed(reason: String)

    /// Stored credentials are no longer valid and the user must sign in again.
    case authorizationExpired

    /// The account is connected, but the granted permissions do not cover this read.
    case insufficientPermissions(reason: String)

    /// The request could not reach the provider.
    case network(reason: String)

    /// The provider reached, but it returned an error.
    case providerFailure(statusCode: Int, reason: String)

    /// The provider's response could not be understood.
    case malformedResponse(reason: String)

    /// The operation was cancelled before it finished.
    case cancelled

    /// Whether retrying the same operation could plausibly succeed.
    var isRetryable: Bool {
        switch self {
        case .network, .providerFailure, .malformedResponse, .cancelled: true
        case .notConfigured, .authenticationFailed, .authorizationExpired, .insufficientPermissions: false
        }
    }

    /// Whether recovering requires the user to sign in again.
    var requiresReauthentication: Bool {
        switch self {
        case .authorizationExpired, .insufficientPermissions: true
        default: false
        }
    }
}

nonisolated extension MailProviderError: LocalizedError {

    /// A short, plain-language headline for the error UI.
    var errorDescription: String? {
        switch self {
        case .notConfigured: "InboxSweep isn't set up to connect yet"
        case .authenticationFailed: "Sign-in didn't complete"
        case .authorizationExpired: "InboxSweep needs permission again"
        case .insufficientPermissions: "InboxSweep doesn't have permission to read this mailbox"
        case .network: "Couldn't reach the mail provider"
        case .providerFailure: "The mail provider returned an error"
        case .malformedResponse: "The mail provider sent something InboxSweep couldn't read"
        case .cancelled: "Loading was cancelled"
        }
    }

    /// A sentence or two of detail, safe to display.
    var failureReason: String? {
        switch self {
        case .notConfigured(let reason): reason
        case .authenticationFailed(let reason): reason
        case .authorizationExpired:
            "The previous authorization is no longer valid. This can happen if it expired or was revoked from your Google Account."
        case .insufficientPermissions(let reason): reason
        case .network(let reason): reason
        case .providerFailure(let statusCode, let reason): "\(reason) (status \(statusCode))"
        case .malformedResponse(let reason): reason
        case .cancelled: "No mailbox data was changed."
        }
    }

    /// What the user can do about it.
    var recoverySuggestion: String? {
        switch self {
        case .notConfigured: "Follow the OAuth setup steps in the project README, then try again."
        case .authenticationFailed: "Try connecting again."
        case .authorizationExpired, .insufficientPermissions: "Connect your account again to continue."
        case .network: "Check your internet connection and try again."
        case .providerFailure: "This is usually temporary. Try again in a moment."
        case .malformedResponse: "Try again. If it keeps happening, this is a bug in InboxSweep."
        case .cancelled: "Load again whenever you're ready."
        }
    }
}

nonisolated extension MailProviderError {

    /// Maps an arbitrary error onto the closest case, preserving cancellation.
    ///
    /// Cancellation is checked first and explicitly: a cancelled load is a normal outcome of
    /// the user changing their mind, and reporting it as a provider failure would show them
    /// an alarming error for something they did on purpose.
    static func wrapping(_ error: Error) -> MailProviderError {
        if let providerError = error as? MailProviderError { return providerError }
        if error is CancellationError { return .cancelled }

        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return .cancelled }
            return .network(reason: urlError.localizedDescription)
        }

        if error is DecodingError {
            return .malformedResponse(reason: "The response didn't match the expected format.")
        }

        return .providerFailure(statusCode: 0, reason: "An unexpected error occurred.")
    }
}

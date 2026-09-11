import AppKit
import AuthenticationServices
import Foundation

/// Presents an OAuth consent screen and returns the URL the provider redirects back to.
///
/// Abstracted so sign-in can be driven by a fake in tests. It is also the only place in the
/// app that shows Google's UI — InboxSweep never renders a password field of its own, and the
/// user's Google credentials are typed into Google's page, not into this app.
nonisolated protocol WebAuthenticating: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// The production implementation, backed by `ASWebAuthenticationSession`.
nonisolated struct WebAuthenticationSessionPresenter: WebAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await WebAuthenticationSessionRunner(url: url, callbackScheme: callbackScheme).run()
    }
}

/// Bridges `ASWebAuthenticationSession`'s completion handler into `async`/`await`.
///
/// Retains the session for the duration of the flow: `ASWebAuthenticationSession` cancels
/// itself when deallocated, so holding it in a local variable would make sign-in fail
/// intermittently.
@MainActor
private final class WebAuthenticationSessionRunner: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let url: URL
    private let callbackScheme: String
    private var session: ASWebAuthenticationSession?

    init(url: URL, callbackScheme: String) {
        self.url = url
        self.callbackScheme = callbackScheme
    }

    func run() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // `@Sendable` is load-bearing, not decoration. `ASWebAuthenticationSession`
                // delivers this callback on its XPC reply queue, never on the main queue. A
                // plain closure literal written here would inherit this class's `@MainActor`
                // isolation, and Swift's dynamic isolation check would then trap the process
                // the moment Google redirected back — a crash on the app's one sign-in path.
                // A `@Sendable` closure carries no isolation, so no check is inserted and the
                // callback is free to arrive wherever it actually arrives.
                let completion: @Sendable (URL?, Error?) -> Void = { callbackURL, error in
                    continuation.resume(with: WebAuthenticationOutcome.result(callbackURL: callbackURL, error: error))
                }

                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme,
                    completionHandler: completion
                )

                session.presentationContextProvider = self
                // Do not reuse the browser's existing session: the user chooses an account
                // explicitly, and this sign-in leaves nothing behind in Safari.
                session.prefersEphemeralWebBrowserSession = true
                self.session = session

                guard session.start() else {
                    self.session = nil
                    continuation.resume(
                        throwing: MailProviderError.authenticationFailed(
                            reason: "InboxSweep couldn't open the Google sign-in window."
                        )
                    )
                    return
                }
            }
        } onCancel: { [self] in
            Task { @MainActor in self.cancel() }
        }
    }

    private func cancel() {
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        }
    }
}

/// Interprets what `ASWebAuthenticationSession` hands back when a sign-in ends.
///
/// A separate, `nonisolated` type rather than a method on the runner, because this code runs on
/// the session's XPC reply queue and nowhere near the main actor. Keeping it out of an
/// actor-isolated class is what makes that true by construction — and makes it callable from a
/// test running off the main actor, which is where the real callback arrives.
nonisolated enum WebAuthenticationOutcome {

    /// The redirect URL, or the reason there isn't one.
    ///
    /// Touches no state at all: given the same pair, it returns the same result on any thread.
    static func result(callbackURL: URL?, error: Error?) -> Result<URL, Error> {
        if let callbackURL { return .success(callbackURL) }
        return .failure(mapped(error))
    }

    /// Translates the framework's error into one the UI can explain.
    ///
    /// Backing out of Google's sheet is ``MailProviderError/cancelled`` — a decision, not a
    /// failure — and the session layer treats it as one.
    static func mapped(_ error: Error?) -> Error {
        guard let error = error as? ASWebAuthenticationSessionError else {
            return MailProviderError.authenticationFailed(reason: "Sign-in didn't return a result.")
        }

        switch error.code {
        case .canceledLogin:
            return MailProviderError.cancelled
        case .presentationContextNotProvided, .presentationContextInvalid:
            return MailProviderError.authenticationFailed(
                reason: "InboxSweep couldn't present the Google sign-in window."
            )
        default:
            return MailProviderError.authenticationFailed(reason: "Sign-in didn't complete.")
        }
    }
}

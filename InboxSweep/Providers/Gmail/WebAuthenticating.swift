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
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme
                ) { callbackURL, error in
                    if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else {
                        continuation.resume(throwing: Self.mapped(error))
                    }
                }

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

    private static func mapped(_ error: Error?) -> Error {
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

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        }
    }
}

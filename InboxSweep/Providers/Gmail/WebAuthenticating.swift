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

/// Drives one `ASWebAuthenticationSession` and bridges its completion handler into `await`.
///
/// The split of isolation here is the whole point of this type. Creating, presenting and
/// cancelling the session are main-actor work, because they are AppKit work: the session
/// shows a window, and it asks this object for the window to show it over. The *callback* is
/// not main-actor work, and must not be treated as if it were —
/// ``WebAuthenticationCallback/sessionCompletionHandler()`` explains why. Everything the
/// callback produces re-enters this class only after `run()` resumes, which is back on the
/// main actor by construction.
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
        let callback = WebAuthenticationCallback()

        // Runs on the main actor whichever way `run()` exits — returned, thrown or cancelled —
        // so the window is always dismissed and the session always released exactly once.
        defer { tearDown() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A task cancelled before it got here has already been answered. Presenting a
                // sign-in window for it would put UI on screen that nothing is waiting for.
                guard callback.attach(continuation) else { return }

                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme,
                    completionHandler: callback.sessionCompletionHandler()
                )

                session.presentationContextProvider = self
                // Do not reuse the browser's existing session: the user chooses an account
                // explicitly, and this sign-in leaves nothing behind in Safari.
                session.prefersEphemeralWebBrowserSession = true
                // Held for the whole attempt: `ASWebAuthenticationSession` cancels itself when
                // deallocated, and `presentationContextProvider` is a weak reference back here.
                self.session = session

                guard session.start() else {
                    callback.finish(.failure(.authenticationFailed(
                        reason: "InboxSweep couldn't open the Google sign-in window."
                    )))
                    return
                }
            }
        } onCancel: {
            // Runs on whatever thread cancelled the task, and may run before the continuation
            // was attached. Answering the callback is all that is needed: that resumes `run()`,
            // which tears the session down on the main actor in its `defer`.
            callback.finish(.failure(.cancelled))
        }
    }

    private func tearDown() {
        session?.cancel()
        session = nil
    }

    /// `ASWebAuthenticationPresentationContextProviding` is declared `NS_SWIFT_UI_ACTOR`, so
    /// this requirement is main-actor-isolated and satisfied by a main-actor method. That is
    /// what makes reading AppKit's window list here correct rather than merely usual.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

import AuthenticationServices
import Foundation
import Testing
@testable import InboxSweep

/// Covers the bridge between `ASWebAuthenticationSession`'s Objective-C completion handler and
/// `async`/`await`.
///
/// The bug these exist for: the handler used to be a closure literal written inside a
/// `@MainActor` class, so it inherited main-actor isolation, and the compiler guarded its body
/// with an executor precondition. AuthenticationServices calls back from its own XPC queue, so
/// that precondition failed with `_dispatch_assert_queue_fail`, "BUG IN CLIENT OF
/// LIBDISPATCH", *before* the first line of the handler ran, which is why hopping to the main actor inside
/// the handler could not have saved it.
///
/// Every test here therefore delivers its result from a queue that is not the main queue, and
/// several are `@MainActor` so that a handler which re-acquired main-actor isolation would trap
/// exactly as the app did.
@Suite("Web authentication callback")
struct WebAuthenticationCallbackTests {

    /// Delivers `callbackURL`/`error` the way AuthenticationServices does: on a background
    /// queue, with no Swift task and no actor underneath it.
    private func deliverOffMainQueue(
        _ handler: @escaping @Sendable (URL?, (any Error)?) -> Void,
        _ callbackURL: URL?,
        _ error: (any Error)? = nil
    ) {
        // A global queue, so there is no Swift task, no actor and no main queue underneath
        // the handler: exactly the context AuthenticationServices calls back from.
        DispatchQueue.global(qos: .userInitiated).async {
            handler(callbackURL, error)
        }
    }

    private func award(_ callback: WebAuthenticationCallback) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            #expect(callback.attach(continuation))
        }
    }

    // MARK: - The crash

    @MainActor
    @Test("A callback delivered from a background queue resumes the caller instead of trapping")
    func survivesBackgroundCallback() async throws {
        let callback = WebAuthenticationCallback()
        let redirect = URL(string: "com.googleusercontent.apps.1234-abc:/oauth2redirect?code=auth-code&state=s")!

        let url = try await withCheckedThrowingContinuation { continuation in
            #expect(callback.attach(continuation))
            deliverOffMainQueue(callback.sessionCompletionHandler(), redirect)
        }

        // The redirect has to survive the hop intact: the authorization code and the `state`
        // the app is about to validate both live in it.
        #expect(url == redirect)
        #expect(FakeWebAuthenticator.queryValue("code", in: url) == "auth-code")
        #expect(FakeWebAuthenticator.queryValue("state", in: url) == "s")
    }

    @MainActor
    @Test("Control returns to the main actor after a background callback resumes it")
    func resumesBackOnTheMainActor() async throws {
        let callback = WebAuthenticationCallback()
        let redirect = URL(string: "com.googleusercontent.apps.1234-abc:/oauth2redirect?code=c&state=s")!

        _ = try await withCheckedThrowingContinuation { continuation in
            #expect(callback.attach(continuation))
            deliverOffMainQueue(callback.sessionCompletionHandler(), redirect)
        }

        // A `@MainActor` caller must be back on the main actor here, so the session state it
        // goes on to write is written where the UI can observe it.
        MainActor.assertIsolated()
    }

    // MARK: - Error mapping across the hop

    @MainActor
    @Test("Dismissing the sign-in window from a background callback reads as cancellation")
    func mapsCancellationFromBackgroundQueue() async {
        let callback = WebAuthenticationCallback()
        let cancelled = ASWebAuthenticationSessionError(.canceledLogin)

        await #expect(throws: MailProviderError.cancelled) {
            try await withCheckedThrowingContinuation { continuation in
                #expect(callback.attach(continuation))
                deliverOffMainQueue(callback.sessionCompletionHandler(), nil, cancelled)
            }
        }
    }

    @MainActor
    @Test("A presentation failure from a background callback propagates as a sign-in failure")
    func mapsPresentationFailureFromBackgroundQueue() async throws {
        let callback = WebAuthenticationCallback()
        let failure = ASWebAuthenticationSessionError(.presentationContextNotProvided)

        let error = await #expect(throws: MailProviderError.self) {
            try await withCheckedThrowingContinuation { continuation in
                #expect(callback.attach(continuation))
                deliverOffMainQueue(callback.sessionCompletionHandler(), nil, failure)
            }
        }

        #expect(try #require(error?.failureReason).contains("couldn't present"))
        #expect(error?.requiresReauthentication == false)
    }

    @Test("A callback with neither a URL nor a recognisable error is a failure, not an empty success")
    func mapsResultlessCallback() async {
        let callback = WebAuthenticationCallback()

        await #expect(throws: MailProviderError.authenticationFailed(
            reason: "Sign-in didn't return a result."
        )) {
            try await withCheckedThrowingContinuation { continuation in
                #expect(callback.attach(continuation))
                deliverOffMainQueue(callback.sessionCompletionHandler(), nil, nil)
            }
        }
    }

    // MARK: - Resuming exactly once

    @Test("Many concurrent callbacks resume the continuation exactly once")
    func resumesExactlyOnce() async throws {
        let callback = WebAuthenticationCallback()
        let handler = callback.sessionCompletionHandler()
        let redirect = URL(string: "com.googleusercontent.apps.1234-abc:/oauth2redirect?code=first&state=s")!

        let url = try await withCheckedThrowingContinuation { continuation in
            #expect(callback.attach(continuation))

            // A real attempt can race the framework's callback against the task being
            // cancelled. `CheckedContinuation` traps on a second resume, so this test failing
            // to crash (and returning the *first* result) is the assertion.
            DispatchQueue.concurrentPerform(iterations: 32) { iteration in
                if iteration == 0 {
                    handler(redirect, nil)
                } else if iteration.isMultiple(of: 2) {
                    handler(nil, ASWebAuthenticationSessionError(.canceledLogin))
                } else {
                    callback.finish(.failure(.cancelled))
                }
            }
        }

        #expect(url == redirect)

        // Late results after the caller has already resumed are dropped, not delivered.
        handler(nil, ASWebAuthenticationSessionError(.canceledLogin))
        callback.finish(.success(redirect))
    }

    @Test("A result that arrives before the caller suspends is not lost")
    func keepsResultThatBeatsTheContinuation() async {
        let callback = WebAuthenticationCallback()
        // Cancellation can land before `attach`, because `withTaskCancellationHandler` runs its
        // handler immediately for a task that was already cancelled.
        callback.finish(.failure(.cancelled))

        await #expect(throws: MailProviderError.cancelled) {
            try await withCheckedThrowingContinuation { continuation in
                // `false` is what tells the runner not to present a sign-in window for a task
                // that nothing is waiting on any more.
                #expect(callback.attach(continuation) == false)
            }
        }
    }

    @Test("A redirect that arrives before the caller suspends is delivered to it")
    func keepsRedirectThatBeatsTheContinuation() async throws {
        let callback = WebAuthenticationCallback()
        let redirect = URL(string: "com.googleusercontent.apps.1234-abc:/oauth2redirect?code=early&state=s")!
        callback.sessionCompletionHandler()(redirect, nil)

        let url = try await withCheckedThrowingContinuation { continuation in
            #expect(callback.attach(continuation) == false)
        }

        #expect(url == redirect)
    }
}

import AuthenticationServices
import Foundation
import Synchronization

/// Carries the single result of a sign-in attempt from wherever it is produced to the
/// suspended `async` call that is waiting for it.
///
/// It exists because `ASWebAuthenticationSessionCompletionHandler` is declared in
/// AuthenticationServices without `NS_SWIFT_UI_ACTOR`, so the framework is free to call it on
/// its own XPC queue — and a result can also arrive from the thread that cancels the task.
/// Neither of those is the main actor, so nothing here touches actor-isolated state; the
/// caller hops back to the main actor after it resumes.
///
/// The lock is what makes "resume exactly once" true rather than merely likely: the
/// continuation is *removed* from the state under it, so only the first caller ever sees it.
nonisolated final class WebAuthenticationCallback: Sendable {

    /// What a sign-in attempt produces. `MailProviderError` is the only failure it can carry,
    /// which keeps the result `Sendable` and keeps error mapping in one place.
    typealias Outcome = Result<URL, MailProviderError>

    private enum State {
        /// Neither the continuation nor a result has arrived yet.
        case idle
        /// The caller is suspended on this continuation.
        case waiting(CheckedContinuation<URL, any Error>)
        /// A result arrived before the continuation was attached — cancellation can do this.
        case settled(Outcome)
        /// The continuation has been resumed. Every later result is ignored.
        case finished
    }

    private let state = Mutex<State>(.idle)

    // MARK: - Waiting side

    /// Hands over the continuation the caller is suspended on.
    ///
    /// Returns `false` when the attempt has already finished, in which case the continuation
    /// has just been resumed and the caller must not go on to present anything: a task
    /// cancelled before it got this far should never open a sign-in window.
    func attach(_ continuation: CheckedContinuation<URL, any Error>) -> Bool {
        let alreadySettled: Outcome? = state.withLock { state in
            switch state {
            case .idle:
                state = .waiting(continuation)
                return nil
            case .settled(let outcome):
                state = .finished
                return outcome
            case .waiting, .finished:
                preconditionFailure("A sign-in attempt attached its continuation more than once.")
            }
        }

        guard let alreadySettled else { return true }
        continuation.resume(with: alreadySettled)
        return false
    }

    // MARK: - Producing side

    /// The completion handler to hand to `ASWebAuthenticationSession`.
    ///
    /// Built here, in a `nonisolated` context, rather than written inline at the call site.
    /// A closure literal formed inside a `@MainActor` type inherits that isolation, and the
    /// compiler then guards the closure body with an executor precondition — which traps in
    /// libdispatch the moment AuthenticationServices calls back from its own queue, before a
    /// single line of the body runs. Returning an explicitly `@Sendable` closure from a
    /// `nonisolated` type is what keeps that precondition from being inserted at all.
    func sessionCompletionHandler() -> @Sendable (URL?, (any Error)?) -> Void {
        { [self] callbackURL, error in
            if let callbackURL {
                finish(.success(callbackURL))
            } else {
                finish(.failure(Self.mapped(error)))
            }
        }
    }

    /// Delivers the attempt's result.
    ///
    /// Safe from any thread and safe to call more than once: everything after the first call
    /// is dropped, so a callback that races the task's cancellation cannot double-resume.
    func finish(_ outcome: Outcome) {
        let continuation: CheckedContinuation<URL, any Error>? = state.withLock { state in
            switch state {
            case .waiting(let continuation):
                state = .finished
                return continuation
            case .idle:
                state = .settled(outcome)
                return nil
            case .settled, .finished:
                return nil
            }
        }

        // Resumed outside the lock on purpose: resuming can run the awaiting task inline, and
        // that code must not find this lock held.
        continuation?.resume(with: outcome)
    }

    // MARK: - Error mapping

    /// Translates an AuthenticationServices failure into the app's vocabulary.
    ///
    /// Dismissing the sign-in window is the user changing their mind, so it maps to
    /// ``MailProviderError/cancelled`` rather than to a failure the UI would apologise for.
    static func mapped(_ error: (any Error)?) -> MailProviderError {
        guard let error = error as? ASWebAuthenticationSessionError else {
            return .authenticationFailed(reason: "Sign-in didn't return a result.")
        }

        switch error.code {
        case .canceledLogin:
            return .cancelled
        case .presentationContextNotProvided, .presentationContextInvalid:
            return .authenticationFailed(
                reason: "InboxSweep couldn't present the Google sign-in window."
            )
        default:
            return .authenticationFailed(reason: "Sign-in didn't complete.")
        }
    }
}

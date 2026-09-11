import Foundation
import Synchronization
@testable import InboxSweep

/// Stands in for the Google consent window.
///
/// Lets tests decide what comes back from sign-in: a valid code, a mismatched `state`, a
/// denial, or a cancellation, without any UI appearing.
struct FakeWebAuthenticator: WebAuthenticating {

    let respond: @Sendable (_ authorizationURL: URL, _ callbackScheme: String) throws -> URL

    /// Whether the answer is delivered through the production callback bridge, on a queue that
    /// is not the main queue: the way `ASWebAuthenticationSession` really answers.
    ///
    /// Off by default so most tests stay simple, and turned on by ``offTheMainQueue`` for the
    /// tests that exist to cover the callback's isolation.
    var deliversOffTheMainQueue = false

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        guard deliversOffTheMainQueue else { return try respond(url, callbackScheme) }

        let callback = WebAuthenticationCallback()
        let outcome: WebAuthenticationCallback.Outcome
        do {
            outcome = .success(try respond(url, callbackScheme))
        } catch {
            outcome = .failure(MailProviderError.wrapping(error))
        }

        return try await withCheckedThrowingContinuation { continuation in
            guard callback.attach(continuation) else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                callback.finish(outcome)
            }
        }
    }

    /// The same responses, but delivered from a background queue through the real bridge.
    ///
    /// This is the shape that used to crash the app: a completion handler that has inherited
    /// `@MainActor` traps in libdispatch when AuthenticationServices calls it from its own
    /// queue, so a fake that always answers inline on the caller's executor cannot catch the
    /// regression.
    var offTheMainQueue: FakeWebAuthenticator {
        var copy = self
        copy.deliversOffTheMainQueue = true
        return copy
    }

    /// Redirects back with an authorization code, echoing the `state` the app sent, which is
    /// what a well-behaved authorization server does.
    static func granting(code: String = "auth-code") -> FakeWebAuthenticator {
        FakeWebAuthenticator { url, scheme in
            let state = Self.queryValue("state", in: url) ?? ""
            return URL(string: "\(scheme):/oauth2redirect?code=\(code)&state=\(state)")!
        }
    }

    /// Redirects back with a `state` that does not match the request.
    static func replayingForeignState() -> FakeWebAuthenticator {
        FakeWebAuthenticator { _, scheme in
            URL(string: "\(scheme):/oauth2redirect?code=auth-code&state=some-other-request")!
        }
    }

    /// The user pressed "Cancel" on Google's consent screen.
    static func denying() -> FakeWebAuthenticator {
        FakeWebAuthenticator { url, scheme in
            let state = Self.queryValue("state", in: url) ?? ""
            return URL(string: "\(scheme):/oauth2redirect?error=access_denied&state=\(state)")!
        }
    }

    /// The user closed the sign-in window.
    static func cancelling() -> FakeWebAuthenticator {
        FakeWebAuthenticator { _, _ in throw MailProviderError.cancelled }
    }

    /// Signs in successfully, then closes the window on every later authorization.
    ///
    /// The shape a permission upgrade needs: the session has to exist before it can be upgraded,
    /// so an authenticator that refused the first sign-in too would never reach the case under
    /// test.
    static func grantingThenCancelling(code: String = "auth-code") -> FakeWebAuthenticator {
        let hasGranted = Mutex(false)
        return FakeWebAuthenticator { url, scheme in
            let isFirst = hasGranted.withLock { granted -> Bool in
                defer { granted = true }
                return !granted
            }
            guard isFirst else { throw MailProviderError.cancelled }
            let state = Self.queryValue("state", in: url) ?? ""
            return URL(string: "\(scheme):/oauth2redirect?code=\(code)&state=\(state)")!
        }
    }

    static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }
}

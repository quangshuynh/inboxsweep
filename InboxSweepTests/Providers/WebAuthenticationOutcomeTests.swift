import AuthenticationServices
import Foundation
import Testing
@testable import InboxSweep

/// The sign-in callback, exercised where it actually runs.
///
/// `ASWebAuthenticationSession` delivers its completion on an XPC reply queue. When that
/// callback inherited the main actor's isolation, Swift's dynamic isolation check trapped the
/// process the moment Google redirected back — the app crashed on its only sign-in path, and
/// no test caught it because every other test drives sign-in through a fake.
///
/// These cases run the callback's logic off the main actor deliberately. They would not have
/// caught the original crash on their own — that took a real redirect — but they pin the
/// property that made it possible to fix: this code is `nonisolated` and touches no state, so
/// it is correct on whatever thread the framework happens to choose.
@Suite("Web authentication outcome")
struct WebAuthenticationOutcomeTests {

    private static let callbackURL = URL(string: "com.example.app:/oauth?code=abc&state=xyz")!

    @Test("A redirect URL is returned, from a task with no actor isolation")
    func returnsTheRedirectOffTheMainActor() async throws {
        let result = await Task.detached {
            WebAuthenticationOutcome.result(callbackURL: Self.callbackURL, error: nil)
        }.value

        #expect(try result.get() == Self.callbackURL)
    }

    @Test("Backing out of Google's sheet is a cancellation, not a failure")
    func treatsUserCancellationAsCancelled() async {
        let error = ASWebAuthenticationSessionError(.canceledLogin)

        let result = await Task.detached {
            WebAuthenticationOutcome.result(callbackURL: nil, error: error)
        }.value

        #expect(throws: MailProviderError.cancelled) { try result.get() }
    }

    @Test(
        "A presentation failure is reported as one the user can act on",
        arguments: [
            ASWebAuthenticationSessionError.Code.presentationContextNotProvided,
            ASWebAuthenticationSessionError.Code.presentationContextInvalid,
        ]
    )
    func explainsPresentationFailures(code: ASWebAuthenticationSessionError.Code) async throws {
        let result = await Task.detached {
            WebAuthenticationOutcome.result(callbackURL: nil, error: ASWebAuthenticationSessionError(code))
        }.value

        guard case .failure(let error) = result, case .authenticationFailed(let reason) = error as? MailProviderError else {
            Issue.record("Expected an authentication failure, got \(result)")
            return
        }
        #expect(reason.contains("present"))
    }

    @Test("A callback with neither a URL nor a recognisable error still produces an error")
    func neverReturnsNothing() async {
        let result = await Task.detached {
            WebAuthenticationOutcome.result(callbackURL: nil, error: nil)
        }.value

        #expect(throws: (any Error).self) { try result.get() }
    }
}

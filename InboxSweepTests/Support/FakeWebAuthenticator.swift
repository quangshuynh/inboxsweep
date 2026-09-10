import Foundation
@testable import InboxSweep

/// Stands in for the Google consent window.
///
/// Lets tests decide what comes back from sign-in — a valid code, a mismatched `state`, a
/// denial, or a cancellation — without any UI appearing.
struct FakeWebAuthenticator: WebAuthenticating {

    let respond: @Sendable (_ authorizationURL: URL, _ callbackScheme: String) throws -> URL

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try respond(url, callbackScheme)
    }

    /// Redirects back with an authorization code, echoing the `state` the app sent — which is
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

    static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }
}

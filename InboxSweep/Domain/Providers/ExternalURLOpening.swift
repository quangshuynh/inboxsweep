import Foundation

/// Hands a URL to the system, for the user to continue with.
///
/// A boundary of its own, distinct from every transport in the app, because what happens on
/// the other side of it is categorically different: nothing is fetched, nothing comes back, and
/// InboxSweep learns nothing except whether macOS accepted the URL. That is what makes browser
/// and mail handoff *handoff* rather than a quieter kind of request — and having it as a
/// protocol is what lets a test prove that the browser path produced no HTTP traffic at all,
/// by handing the session an opener that records and a transport that would have recorded.
///
/// The allow-list lives in ``UnsubscribeHandoff``, not in implementations, so every opener in
/// the app — production, fake, or future — is bound by the same rule.
nonisolated protocol ExternalURLOpening: Sendable {

    /// Asks the system to open `url`, returning whether it accepted.
    ///
    /// Implementations must not fetch, follow, inspect, or rewrite the URL. Opening it is the
    /// whole of the contract.
    func open(_ url: URL) async -> Bool
}

/// The rule about which URLs the app will ever hand to the system.
///
/// Applied before an opener sees a URL, so the check is one thing in one place rather than a
/// convention each implementation is trusted to keep.
nonisolated enum UnsubscribeHandoff {

    /// The only two schemes the app will open, and what each is for.
    ///
    /// `https` goes to a browser; `mailto` goes to a mail client. Everything else is refused —
    /// `http` included, because an unsubscribe page reached over an unencrypted connection is a
    /// page whose form the user is about to fill in.
    static let permittedSchemes: Set<String> = ["https", "mailto"]

    /// Whether this URL may be handed to the system.
    static func permits(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), permittedSchemes.contains(scheme) else { return false }
        if scheme == "https" { return HTTPSUnsubscribeURL(url) != nil }
        return MailtoUnsubscribeAddress(url) != nil
    }

    /// Opens `url` through `opener`, refusing anything outside the allow-list.
    ///
    /// Returns the failure rather than throwing, so a refusal and a decline read the same way
    /// to the caller and neither can be mistaken for success.
    static func open(_ url: URL, with opener: any ExternalURLOpening) async -> UnsubscribeFailure? {
        guard permits(url) else { return .refusedDestination }
        return await opener.open(url) ? nil : .couldNotOpen
    }
}

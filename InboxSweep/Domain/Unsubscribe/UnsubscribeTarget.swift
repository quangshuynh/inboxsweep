import Foundation

/// One value out of a `List-Unsubscribe` header, after it has been parsed and judged.
///
/// ### Why a header value is not a URL
///
/// `List-Unsubscribe` is written by the sender. It arrives as text, it is frequently
/// malformed, and — unlike every other header InboxSweep reads — acting on it means leaving
/// Gmail and contacting a third party. So the text is never carried around as text. It is
/// parsed once, at the provider boundary, into one of the two things the app is willing to do
/// something with, or into ``unsupported`` with a reason.
///
/// Nothing above this type can rebuild a destination from a string: ``HTTPSUnsubscribeURL`` and
/// ``MailtoUnsubscribeAddress`` have failable initializers that are the only way to make one,
/// and both refuse anything that is not the scheme they name. That is what "do not treat
/// arbitrary text as executable" looks like in code rather than in a comment.
nonisolated enum UnsubscribeTarget: Hashable, Sendable, Codable {

    /// An `https` URL. Whether it is *one-click* capable is a separate question — see
    /// ``MessageUnsubscribeMetadata/declaresOneClickPost``.
    case web(HTTPSUnsubscribeURL)

    /// A `mailto` URL. Handed to the user's mail client; never sent by InboxSweep.
    case mail(MailtoUnsubscribeAddress)

    /// A value the app will not act on, and why.
    case unsupported(UnsupportedUnsubscribeValue)

    var webURL: HTTPSUnsubscribeURL? {
        if case .web(let url) = self { return url }
        return nil
    }

    var mailAddress: MailtoUnsubscribeAddress? {
        if case .mail(let address) = self { return address }
        return nil
    }

    var unsupportedValue: UnsupportedUnsubscribeValue? {
        if case .unsupported(let value) = self { return value }
        return nil
    }

    /// Whether this value names a destination the app could act on at all.
    var isActionable: Bool {
        switch self {
        case .web, .mail: true
        case .unsupported: false
        }
    }
}

/// An `https` URL from an unsubscribe header, and the only type in the app that can hold one.
///
/// The initializer is the whole point. It accepts an absolute URL whose scheme is exactly
/// `https` and which has a host, and it refuses everything else — `http`, `javascript`,
/// `file`, `data`, `mailto`, a custom scheme, a relative reference, a URL with no host. A value
/// of this type is therefore a *proof* that a validated HTTPS destination was parsed, and the
/// one-click client's signature asks for that proof rather than for a `URL` it would have to
/// re-check.
nonisolated struct HTTPSUnsubscribeURL: Hashable, Sendable, Codable {

    /// The URL, exactly as the header gave it.
    ///
    /// Exactly: no query parameter is added, removed, or reordered anywhere in the app. A
    /// tracking token the sender put in their own unsubscribe link is theirs; one InboxSweep
    /// appended would be InboxSweep telling a third party something about this user.
    let url: URL

    /// The scheme this type will accept, and the only one.
    static let requiredScheme = "https"

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.requiredScheme else { return nil }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        self.url = url
    }

    /// Parses a string, refusing anything that is not an absolute `https` URL.
    init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        self.init(url)
    }

    /// The host, which is what the review sheet shows the user before they confirm.
    var host: String { url.host(percentEncoded: false) ?? "" }

    /// The registrable-looking tail of the host, for a second, shorter line.
    ///
    /// Presentation only, and deliberately naive — it does not consult a public-suffix list, so
    /// it is never used to decide anything. ``host`` is what the user is shown as the
    /// destination; this is only ever an aid to reading it.
    var displayDomain: String {
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }

    /// The full URL as text, for the "exact destination" line.
    var absoluteString: String { url.absoluteString }
}

/// A `mailto` address from an unsubscribe header.
///
/// Kept structurally distinct from ``HTTPSUnsubscribeURL`` throughout, because the two lead to
/// completely different places: one can be a request InboxSweep makes, the other can only ever
/// be a message *the user* sends from their own mail client. There is no code path that turns
/// one into the other.
nonisolated struct MailtoUnsubscribeAddress: Hashable, Sendable, Codable {

    /// The address to write to.
    let address: String

    /// The `subject` the header asked for, when it carried one.
    ///
    /// Mailing lists routinely require a particular subject (`unsubscribe`), so dropping it
    /// would hand the user a message their list would ignore. Carried for the *mail client* to
    /// prefill; InboxSweep never sends it.
    let subject: String?

    /// The `body` the header asked for, when it carried one.
    let body: String?

    static let requiredScheme = "mailto"

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.requiredScheme else { return nil }

        // `mailto:` puts its address in the opaque path rather than in a host.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = (components?.path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeAnAddress(path) else { return nil }

        address = path
        let items = components?.queryItems ?? []
        subject = items.first { $0.name.caseInsensitiveCompare("subject") == .orderedSame }?.value
        body = items.first { $0.name.caseInsensitiveCompare("body") == .orderedSame }?.value
    }

    init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        self.init(url)
    }

    /// The narrowest check worth making: one `@`, something either side, no whitespace.
    ///
    /// Not an RFC 5322 validator. It is here to reject the values that are obviously not
    /// addresses — an empty `mailto:`, a URL that swallowed the rest of the header — because
    /// this string ends up in a `mailto:` URL handed to the user's mail client.
    private static func looksLikeAnAddress(_ candidate: String) -> Bool {
        guard !candidate.contains(where: \.isWhitespace) else { return false }
        let parts = candidate.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }

    /// The domain the request would be addressed to, for the review sheet.
    var domain: String {
        address.split(separator: "@").last.map(String.init) ?? ""
    }

    /// The `mailto:` URL to hand to the user's mail client, rebuilt from the parsed parts.
    ///
    /// Rebuilt rather than carried through, so what is opened is assembled from values this
    /// type validated rather than from the sender's original string.
    var composeURL: URL? {
        var components = URLComponents()
        components.scheme = Self.requiredScheme
        components.path = address
        var items: [URLQueryItem] = []
        if let subject { items.append(URLQueryItem(name: "subject", value: subject)) }
        if let body { items.append(URLQueryItem(name: "body", value: body)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }
}

/// A header value InboxSweep parsed and will not act on.
///
/// Kept rather than discarded, because "this sender sent an unsubscribe header InboxSweep
/// cannot use" is a different thing to tell somebody than "this sender sent nothing", and the
/// second would be untrue.
nonisolated struct UnsupportedUnsubscribeValue: Hashable, Sendable, Codable {

    nonisolated enum Reason: String, Hashable, Sendable, Codable, CaseIterable {

        /// `http://…` — a URL that is not encrypted.
        ///
        /// Refused rather than upgraded. Rewriting somebody's `http` link to `https` would be
        /// the app inventing a destination the sender did not name.
        case insecureScheme

        /// `javascript:`, `data:`, `file:`, or anything else that is neither `https` nor
        /// `mailto`. Never executed, never opened, never rewritten.
        case disallowedScheme

        /// The value was not bracketed as RFC 2369 requires, so it is text rather than a
        /// destination.
        case notBracketed

        /// Bracketed, but what was inside did not parse as a URL at all.
        case malformed

        /// A `mailto:` whose address was missing or unusable.
        case unusableMailAddress

        /// An `https` URL with no host, which cannot be a destination.
        case missingHost

        var explanation: String {
            switch self {
            case .insecureScheme:
                "an unencrypted http:// link, which InboxSweep will not open or send a request to"
            case .disallowedScheme:
                "a link whose scheme is neither https nor mailto, which InboxSweep never acts on"
            case .notBracketed:
                "a value that wasn't enclosed in < > as the standard requires, so it's text rather than a link"
            case .malformed:
                "a value that isn't a usable link"
            case .unusableMailAddress:
                "a mailto: link with no usable address"
            case .missingHost:
                "an https link with no host"
            }
        }
    }

    let reason: Reason

    /// The scheme that was seen, when there was one.
    ///
    /// The scheme and nothing else. The value itself is deliberately **not** kept: it is
    /// sender-controlled text that could carry an identifier for this mailbox, and it would
    /// then be shown on a screen and, worse, be one refactor from being persisted. The reason
    /// and the scheme are enough to explain the refusal.
    let scheme: String?

    init(reason: Reason, scheme: String? = nil) {
        self.reason = reason
        self.scheme = scheme?.lowercased()
    }
}

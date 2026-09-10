import Foundation

/// The Gmail OAuth scopes InboxSweep asks for — and the ones it must never ask for.
///
/// Interval 1 requests exactly one scope: `gmail.metadata`. That is narrower than the more
/// common `gmail.readonly`, because it does not grant access to message bodies or
/// attachments at all. The app only needs headers, labels, and dates to group mail by sender,
/// so asking for message content would be requesting more access than the feature uses.
///
/// Practical consequence of choosing the narrower scope: Gmail rejects search queries (`q`)
/// and body formats under `gmail.metadata`. The fetch layer is built within those limits
/// rather than widening the scope to work around them.
nonisolated enum GmailScope {

    /// Read message metadata — headers, labels, and dates — but not bodies or attachments.
    static let metadata = "https://www.googleapis.com/auth/gmail.metadata"

    /// The complete set of scopes requested at sign-in.
    static let requested: [String] = [metadata]

    /// Scopes that would grant the ability to change, delete, or send mail.
    ///
    /// Listed explicitly so that a test can assert none of them ever appear in ``requested``.
    /// If a future interval needs one of these, that has to be a deliberate edit here, not a
    /// side effect of a change somewhere else.
    static let prohibitedForReadOnlyOperation: [String] = [
        "https://mail.google.com/",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.compose",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.insert",
        "https://www.googleapis.com/auth/gmail.labels",
        "https://www.googleapis.com/auth/gmail.settings.basic",
        "https://www.googleapis.com/auth/gmail.settings.sharing",
    ]

    /// The space-delimited form Google's authorization endpoint expects.
    static var requestedScopeParameter: String { requested.joined(separator: " ") }

    /// A plain-language description of what the user is being asked to grant.
    static let userFacingDescription = """
        Read-only access to the labels, dates, and headers of your Gmail messages — \
        including who each message is from and its subject line.
        """
}

import Foundation

/// The Gmail OAuth scopes InboxSweep asks for, and the ones it must never ask for.
///
/// ### Two scopes, for two different capabilities
///
/// `gmail.metadata` is what the app reads with. It is narrower than the more common
/// `gmail.readonly` because it does not grant access to message bodies or attachments at all.
///
/// `gmail.modify` is what archiving needs, and it is requested for that and nothing else.
/// Taking a message out of the inbox means removing its `INBOX` label, and `messages.modify` is
/// the Gmail operation that does it. **Google publishes no narrower permission for this.**
/// `gmail.labels` governs creating and deleting label definitions, not applying them to a
/// message; `gmail.insert` and `gmail.compose` are about putting mail *into* a mailbox. The
/// alternative to `gmail.modify` is not a smaller scope: it is not having an archive feature.
///
/// ### Being honest that `gmail.modify` is broad
///
/// It is. It would also permit trashing a message, marking mail read, applying arbitrary
/// labels, and reading message bodies. InboxSweep does none of those, and the limit is
/// structural rather than promised:
///
/// - the only mutating requests the app can build are the two in ``GmailMutationEndpoint``,
///   which add or remove `INBOX` on one named message and take no label parameter;
/// - every read is still `format=metadata` with four named headers, so bodies are not
///   requested even though the grant would now allow it;
/// - `SafetyBoundaryTests` fails if a third mutating request builder appears, if one reaches a
///   trash, delete, send, or settings path, or if any body format is ever requested.
///
/// The signed-out screen says all of this before the user is sent to Google, because "manage
/// your Gmail" on a consent sheet is not informed consent.
nonisolated enum GmailScope {

    /// Read message metadata (headers, labels, and dates) but not bodies or attachments.
    static let metadata = "https://www.googleapis.com/auth/gmail.metadata"

    /// Change which labels a message carries. The narrowest permission that can archive.
    static let modify = "https://www.googleapis.com/auth/gmail.modify"

    /// What a grant must cover for the app to read a mailbox at all.
    ///
    /// A stored grant missing this is unusable and is discarded. A stored grant missing only
    /// ``requiredForArchiving`` is *not*: it still reads perfectly well, and treating it as
    /// broken would sign out every existing user over a feature they have not asked for yet.
    static let requiredForReading: [String] = [metadata]

    /// What a grant must cover before archiving is offered.
    static let requiredForArchiving: [String] = [modify]

    /// The complete set of scopes requested at sign-in.
    static let requested: [String] = [metadata, modify]

    /// Scopes that would let the app do something it has no feature for.
    ///
    /// Listed explicitly so a test can assert none of them ever appears in ``requested``. Note
    /// that `https://mail.google.com/` is here and `gmail.modify` no longer is: the full-access
    /// scope additionally grants *permanent deletion*, which is the one mailbox change that
    /// cannot be undone and therefore the one this app will not hold the power to make.
    static let prohibited: [String] = [
        "https://mail.google.com/",
        "https://www.googleapis.com/auth/gmail.compose",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.insert",
        "https://www.googleapis.com/auth/gmail.labels",
        "https://www.googleapis.com/auth/gmail.settings.basic",
        "https://www.googleapis.com/auth/gmail.settings.sharing",
        "https://www.googleapis.com/auth/contacts",
        "https://www.googleapis.com/auth/contacts.readonly",
    ]

    /// The space-delimited form Google's authorization endpoint expects.
    static var requestedScopeParameter: String { requested.joined(separator: " ") }

    /// Whether a set of granted scopes covers reading.
    static func coversReading<S: Collection<String>>(_ granted: S) -> Bool {
        requiredForReading.allSatisfy(granted.contains)
    }

    /// Whether a set of granted scopes covers archiving.
    static func coversArchiving<S: Collection<String>>(_ granted: S) -> Bool {
        requiredForArchiving.allSatisfy(granted.contains)
    }

    // MARK: - What the user is told

    /// What the read permission grants, in plain language.
    static let readingDescription = """
        Read-only access to the labels, dates, and headers of your Gmail messages, \
        including who each message is from and its subject line.
        """

    /// What the archive permission grants, in plain language.
    ///
    /// Says what Google is actually granting, not what InboxSweep intends to use. Describing
    /// `gmail.modify` as "permission to archive" would be describing the app's restraint as
    /// though it were the permission's limit, and the user cannot check the app's restraint
    /// from the consent screen.
    static let archivingDescription = """
        Permission to change which labels your messages carry, which is what lets InboxSweep \
        archive a message you pick. Google grants this as one permission, so it is broader \
        than archiving: it would also allow marking mail read or moving it to Trash. \
        InboxSweep does neither: the only change it can make is taking one message you \
        explicitly confirm out of your Inbox, and putting it back if you undo.
        """

    /// What is still not granted, and therefore still impossible.
    static let stillNotGrantedDescription = """
        InboxSweep never asks for permission to permanently delete mail, send or draft mail, \
        read message bodies or attachments, or change your Gmail settings or contacts.
        """
}

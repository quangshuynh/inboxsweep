import Foundation

/// What one message's unsubscribe headers turned out to be.
///
/// Held on ``MailMessage`` in place of the Boolean the previous intervals kept there. The
/// Boolean was the right shape while the app's entire relationship with the header was "note
/// that it was there"; it is the wrong shape now that a user can be shown a destination and
/// asked to confirm it, because "a header was present" and "a usable HTTPS endpoint was
/// declared" are answers to different questions and only one of them can lead to an action.
///
/// Parsed at the provider boundary, by ``ListUnsubscribeParser``. Nothing above that boundary
/// ever sees the raw header text, which is what keeps sender-controlled text from travelling
/// through the app as a string that could later be handed to a URL loader.
nonisolated struct MessageUnsubscribeMetadata: Hashable, Sendable, Codable {

    /// Every value the header carried, in header order, including the refused ones.
    let targets: [UnsubscribeTarget]

    /// Whether `List-Unsubscribe-Post: List-Unsubscribe=One-Click` was present, exactly.
    ///
    /// On its own this means nothing; see ``oneClickURL``, which is the question anything
    /// acting on it must ask. A sender can declare one-click and provide only a `mailto`, which
    /// is contradictory metadata rather than a one-click mechanism.
    let declaresOneClickPost: Bool

    /// Whether the message carried a `List-Unsubscribe` header at all.
    ///
    /// The distinction that makes "no evidence" and "ambiguous metadata" separate states:
    /// `targets` can be empty either because there was no header, or because every value in it
    /// was refused.
    let headerWasPresent: Bool

    init(targets: [UnsubscribeTarget], declaresOneClickPost: Bool, headerWasPresent: Bool) {
        self.targets = targets
        self.declaresOneClickPost = declaresOneClickPost
        self.headerWasPresent = headerWasPresent
    }

    /// No `List-Unsubscribe` header on this message.
    static let absent = MessageUnsubscribeMetadata(
        targets: [],
        declaresOneClickPost: false,
        headerWasPresent: false
    )

    /// A header was present, but its values were not recorded.
    ///
    /// What a message built from the older Boolean means, and what a cache file written before
    /// this interval decodes to. It is honest about the gap: something was there, and this
    /// build cannot say what, which lands the sender in the ambiguous state rather than in
    /// either "nothing here" or a mechanism nobody parsed.
    static let headerPresentUnparsed = MessageUnsubscribeMetadata(
        targets: [],
        declaresOneClickPost: false,
        headerWasPresent: true
    )

    // MARK: - Derived

    /// Whether this message carried the header. The observation the dashboard has always shown.
    var hasListUnsubscribeHeader: Bool { headerWasPresent }

    /// The HTTPS destinations, in header order.
    var webURLs: [HTTPSUnsubscribeURL] { targets.compactMap(\.webURL) }

    /// The mail destinations, in header order.
    var mailAddresses: [MailtoUnsubscribeAddress] { targets.compactMap(\.mailAddress) }

    /// The values that were refused, in header order.
    var unsupportedValues: [UnsupportedUnsubscribeValue] { targets.compactMap(\.unsupportedValue) }

    /// Whether anything here could be acted on.
    var hasActionableTarget: Bool { targets.contains(where: \.isActionable) }

    /// The one-click endpoint, when the metadata really declares one.
    ///
    /// **Both halves are required.** RFC 8058 one-click is a POST to an HTTPS URL from the
    /// `List-Unsubscribe` header, authorised by a `List-Unsubscribe-Post` header beside it.
    /// Neither header means one-click on its own, and this is the only place in the app that
    /// decides the question, so a POST cannot be reached from a URL that merely looks like an
    /// endpoint.
    ///
    /// The *first* HTTPS value wins when there are several, which is the rule
    /// ``UnsubscribeMechanismSelection`` documents and tests.
    var oneClickURL: HTTPSUnsubscribeURL? {
        guard declaresOneClickPost else { return nil }
        return webURLs.first
    }

    /// Whether the sender declared one-click but supplied nothing it could apply to.
    ///
    /// Contradictory metadata: reported as evidence and never resolved by guessing. The user is
    /// offered whatever *is* usable (a browser page, a mail handoff) and told the declaration
    /// did not match.
    var declaresOneClickWithoutHTTPSURL: Bool {
        declaresOneClickPost && webURLs.isEmpty
    }

    /// Whether this metadata says anything at all.
    var isEmpty: Bool { !headerWasPresent && targets.isEmpty }
}

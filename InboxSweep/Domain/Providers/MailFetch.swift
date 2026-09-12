import Foundation

/// An opaque provider cursor for the next page of results.
nonisolated struct MailPageToken: Hashable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Which part of the mailbox to read.
///
/// Every case maps to a label the provider already applies: there is no search query here and
/// there could not be one, because `gmail.metadata` forbids `q=`. Widening the scope to gain
/// search would mean asking for access to message bodies, which is the one thing this app is
/// built not to do.
///
/// The category cases are **Gmail's own classification**, not the app's. Choosing *Promotions*
/// asks Gmail for the mail Gmail already filed there; InboxSweep does not decide what belongs.
nonisolated enum MailboxScope: String, Hashable, Sendable, CaseIterable, Identifiable {

    /// Messages currently in the inbox, whatever category they carry.
    case inbox

    /// Gmail's Promotions category.
    case promotions

    /// Gmail's Updates category.
    case updates

    /// Gmail's Social category.
    case social

    /// Gmail's Forums category.
    case forums

    /// Everything the provider will list, including archived mail.
    case allMail

    var id: String { rawValue }

    /// The scopes offered in the UI, in the order they are shown.
    ///
    /// Inbox leads because it is what the app is for. *All mail* sits last because it is the
    /// one that can take a long time and reach furthest back.
    static let offered: [MailboxScope] = [.inbox, .promotions, .updates, .social, .forums, .allMail]

    var displayName: String {
        switch self {
        case .inbox: "Inbox"
        case .promotions: "Promotions"
        case .updates: "Updates"
        case .social: "Social"
        case .forums: "Forums"
        case .allMail: "All mail"
        }
    }

    /// The noun a sentence about this scope uses: "your inbox", "your Promotions category".
    var possessivePhrase: String {
        switch self {
        case .inbox: "your inbox"
        case .allMail: "your mailbox"
        case .promotions, .updates, .social, .forums: "your \(displayName) category"
        }
    }

    /// Whether this scope is one of Gmail's own inbox categories.
    var isProviderCategory: Bool {
        switch self {
        case .promotions, .updates, .social, .forums: true
        case .inbox, .allMail: false
        }
    }

    /// Whether a message carrying these labels still belongs in a window read from this
    /// scope.
    ///
    /// Exists because archiving changes the answer. A window is whatever the provider would
    /// list for this scope, and after a message loses its `INBOX` label an inbox-scoped list
    /// would not return it, so the loaded window must stop counting it, or a refresh would
    /// disagree with what is on screen.
    ///
    /// Only the inbox scope can lose a message this way. Gmail's category labels survive an
    /// archive untouched and *All mail* lists archived mail by definition, so a message
    /// archived while one of those is loaded stays in the window, which is exactly what a
    /// refresh would return.
    func retains(_ message: MailMessage) -> Bool {
        switch self {
        case .inbox: message.labels.contains(.inbox)
        case .promotions, .updates, .social, .forums, .allMail: true
        }
    }

    /// What reading this scope does and does not cover, for the UI to say out loud.
    var coverageCaveat: String {
        switch self {
        case .inbox:
            "Mail outside the inbox (already archived, sent, or filed under other labels) is not read."
        case .allMail:
            "This reaches archived mail as well as the inbox."
        case .promotions, .updates, .social, .forums:
            "This is Gmail's own \(displayName) category. InboxSweep reports what Gmail filed there; it does not classify mail itself."
        }
    }
}

/// A bounded request for message metadata.
nonisolated struct MailFetchRequest: Hashable, Sendable {

    /// The default size of the first window.
    ///
    /// Large enough that the sender dashboard says something useful about a real mailbox,
    /// small enough that the first screen appears quickly and the provider's per-user rate
    /// limits are not a concern.
    static let defaultLimit = 250

    /// Maximum messages to return in this page. Clamped to `1...500`.
    let limit: Int

    /// Cursor from a previous page, or `nil` for the first page.
    let pageToken: MailPageToken?

    /// Which part of the mailbox to read.
    let scope: MailboxScope

    init(limit: Int = defaultLimit, pageToken: MailPageToken? = nil, scope: MailboxScope = .inbox) {
        self.limit = min(max(limit, 1), 500)
        self.pageToken = pageToken
        self.scope = scope
    }

    /// The same request positioned at the next page.
    func nextPage(after token: MailPageToken) -> MailFetchRequest {
        MailFetchRequest(limit: limit, pageToken: token, scope: scope)
    }
}

/// One page of message metadata.
nonisolated struct MailMessagePage: Sendable, Equatable {

    /// The messages in this page, newest first as reported by the provider.
    let messages: [MailMessage]

    /// Cursor for the following page, or `nil` when the window is exhausted.
    let nextPageToken: MailPageToken?

    init(messages: [MailMessage], nextPageToken: MailPageToken? = nil) {
        self.messages = messages
        self.nextPageToken = nextPageToken
    }

    var hasMorePages: Bool { nextPageToken != nil }

    static let empty = MailMessagePage(messages: [], nextPageToken: nil)
}

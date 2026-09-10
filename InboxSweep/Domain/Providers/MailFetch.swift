import Foundation

/// An opaque provider cursor for the next page of results.
nonisolated struct MailPageToken: Hashable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Which part of the mailbox to read.
///
/// Only the cases the app actually uses are modelled. Adding scopes we do not need would be
/// inventing provider capabilities before there is a feature that wants them.
nonisolated enum MailboxScope: Hashable, Sendable {
    /// Messages currently in the inbox.
    case inbox
    /// Everything the provider will list, including archived mail.
    case allMail
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

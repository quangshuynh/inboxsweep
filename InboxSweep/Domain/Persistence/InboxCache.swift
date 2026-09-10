import Foundation

/// One account's loaded window, as it was when it was last saved.
///
/// This is the unit the app persists between launches. It carries the messages themselves
/// rather than only the summaries, because the summaries are derived from them and because
/// paging and per-sender message lists both need the underlying window back.
///
/// Still metadata only: it holds ``MailMessage`` values, which have nowhere to put a message
/// body, so a cache file cannot contain mail content even in principle.
nonisolated struct CachedInbox: Equatable, Sendable {

    /// The account this window belongs to. A cache is never read back for a different account.
    let account: MailAccount

    /// The loaded messages, in the order the provider returned them.
    let messages: [MailMessage]

    /// The sender summaries derived from ``messages`` at save time.
    let senders: [SenderSummary]

    /// The provider cursor for the page after this window, when there was one.
    ///
    /// Persisted so that "Load more messages" keeps working after a relaunch instead of
    /// restarting from the top of the mailbox.
    let nextPageToken: MailPageToken?

    /// When this window was written.
    let savedAt: Date

    init(
        account: MailAccount,
        messages: [MailMessage],
        senders: [SenderSummary],
        nextPageToken: MailPageToken?,
        savedAt: Date
    ) {
        self.account = account
        self.messages = messages
        self.senders = senders
        self.nextPageToken = nextPageToken
        self.savedAt = savedAt
    }

    /// Whether the stored summaries still describe the stored messages.
    ///
    /// Summaries are derived data, and derived data kept alongside its source can drift — a
    /// half-written file, or a build whose aggregation rules have changed. When this is
    /// `false` the summaries are rebuilt from the messages rather than trusted.
    var summariesMatchMessages: Bool {
        senders.reduce(0) { $0 + $1.messageCount } == messages.count
    }
}

/// Local storage for a loaded window.
///
/// Deliberately non-throwing. A cache is an optimisation: failing to read one means a normal
/// fetch, and failing to write one means the next launch fetches again. Neither is worth
/// showing the user an error about, and neither should be able to fail an operation that has
/// otherwise succeeded.
///
/// Implementations must keep at most one account's window at a time, so signing into a second
/// account does not leave the first one's metadata on disk.
nonisolated protocol InboxCacheStoring: Sendable {

    /// Returns the stored window for `account`, or `nil` when there is none to use.
    ///
    /// Returns `nil` — never throws — for a missing, unreadable, corrupt, out-of-date, or
    /// wrong-account file.
    func load(for account: MailAccount) async -> CachedInbox?

    /// Replaces the stored window. Any other account's stored window is discarded.
    func save(_ inbox: CachedInbox) async

    /// Removes the stored window for `account`.
    func clear(for account: MailAccount) async
}

/// A cache that keeps nothing.
///
/// The default, so persistence is something a caller opts into rather than something that
/// happens by surprise. Used for the synthetic mailbox, which has no business writing
/// invented mail to disk.
nonisolated struct EphemeralInboxCache: InboxCacheStoring {
    init() {}
    func load(for account: MailAccount) async -> CachedInbox? { nil }
    func save(_ inbox: CachedInbox) async {}
    func clear(for account: MailAccount) async {}
}

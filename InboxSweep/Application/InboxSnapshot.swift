import Foundation

/// Everything the dashboard needs to render one loaded window of a mailbox.
nonisolated struct InboxSnapshot: Equatable, Sendable {

    /// The connected account.
    let account: MailAccount

    /// How many messages have been loaded so far.
    let loadedMessageCount: Int

    /// One entry per distinct sender, already ordered by ``sortOrder``.
    let senders: [SenderSummary]

    /// The order ``senders`` is currently in.
    let sortOrder: SenderSortOrder

    /// Whether the provider has more messages beyond the loaded window.
    let hasMoreMessages: Bool

    /// Whether another page is being fetched right now.
    let isLoadingMore: Bool

    /// When this window was written to the local cache, or `nil` when it was read from the
    /// provider during this launch.
    ///
    /// Carried into the UI so a window restored from disk is labelled as one. A dashboard that
    /// looked identical whether the mail was read a moment ago or last week would be quietly
    /// misleading about how current its counts are.
    let cachedAt: Date?

    init(
        account: MailAccount,
        loadedMessageCount: Int,
        senders: [SenderSummary],
        sortOrder: SenderSortOrder,
        hasMoreMessages: Bool,
        isLoadingMore: Bool,
        cachedAt: Date? = nil
    ) {
        self.account = account
        self.loadedMessageCount = loadedMessageCount
        self.senders = senders
        self.sortOrder = sortOrder
        self.hasMoreMessages = hasMoreMessages
        self.isLoadingMore = isLoadingMore
        self.cachedAt = cachedAt
    }

    /// Whether what is on screen was restored from disk rather than read this launch.
    var isRestoredFromCache: Bool { cachedAt != nil }

    /// Number of distinct senders in the loaded window.
    var senderCount: Int { senders.count }

    /// Whether the load succeeded but found nothing.
    var isEmpty: Bool { loadedMessageCount == 0 }

    /// The oldest message date in the window — how far back the app has actually looked.
    var oldestLoadedDate: Date? {
        senders.map(\.oldestLoadedReceivedAt).min()
    }

    /// Total unread messages across the loaded window.
    var unreadMessageCount: Int {
        senders.reduce(0) { $0 + $1.unreadCount }
    }

    func replacingSortOrder(_ newOrder: SenderSortOrder) -> InboxSnapshot {
        InboxSnapshot(
            account: account,
            loadedMessageCount: loadedMessageCount,
            senders: SenderAggregator.sort(senders, by: newOrder),
            sortOrder: newOrder,
            hasMoreMessages: hasMoreMessages,
            isLoadingMore: isLoadingMore,
            cachedAt: cachedAt
        )
    }

    func settingLoadingMore(_ isLoadingMore: Bool) -> InboxSnapshot {
        InboxSnapshot(
            account: account,
            loadedMessageCount: loadedMessageCount,
            senders: senders,
            sortOrder: sortOrder,
            hasMoreMessages: hasMoreMessages,
            isLoadingMore: isLoadingMore,
            cachedAt: cachedAt
        )
    }
}

/// What the app is doing, and therefore what the window shows.
nonisolated enum InboxSessionState: Equatable, Sendable {

    /// No account connected. The starting state, and where signing out returns to.
    case signedOut

    /// Re-establishing a previously authorized connection at launch, without user interaction.
    case restoring

    /// An interactive sign-in is in progress.
    case connecting

    /// Connected, fetching the first window.
    case loading(MailAccount)

    /// A window is loaded. An empty mailbox is this state with a zero count, not a separate one.
    case loaded(InboxSnapshot)

    /// Something went wrong. `account` is non-nil when the failure happened after connecting,
    /// which is what tells the UI whether to offer "Try again" or "Connect".
    case failed(MailProviderError, account: MailAccount?)

    var snapshot: InboxSnapshot? {
        if case .loaded(let snapshot) = self { return snapshot }
        return nil
    }

    /// Whether a long-running operation is in flight and can be cancelled.
    var isBusy: Bool {
        switch self {
        case .restoring, .connecting, .loading: true
        case .loaded(let snapshot): snapshot.isLoadingMore
        case .signedOut, .failed: false
        }
    }
}

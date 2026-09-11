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

    /// Which part of the mailbox this window was read from.
    ///
    /// Carried on the snapshot rather than asked of the session, so every number rendered
    /// beside it is guaranteed to describe the same slice of mail. A header that said
    /// "Promotions" over counts taken from the inbox would be worse than saying nothing.
    let scope: MailboxScope

    /// How many pages have been read into this window.
    ///
    /// Shown while a deep load runs, so waiting has something to watch that is not a spinner.
    let loadedPageCount: Int

    /// One proposal per sender, keyed by the same grouping key ``senders`` are identified by.
    ///
    /// Derived data, recomputed from the loaded window every time it changes and never
    /// persisted; see ``CleanupProposalRules/version``. A dictionary rather than a parallel
    /// array so re-sorting ``senders`` cannot put a row next to somebody else's proposal.
    let proposals: [SenderSummary.ID: SenderCleanupProposal]

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
        scope: MailboxScope = .inbox,
        hasMoreMessages: Bool,
        isLoadingMore: Bool,
        loadedPageCount: Int = 1,
        proposals: [SenderSummary.ID: SenderCleanupProposal] = [:],
        cachedAt: Date? = nil
    ) {
        self.account = account
        self.loadedMessageCount = loadedMessageCount
        self.senders = senders
        self.sortOrder = sortOrder
        self.scope = scope
        self.proposals = proposals
        self.hasMoreMessages = hasMoreMessages
        self.isLoadingMore = isLoadingMore
        self.loadedPageCount = loadedPageCount
        self.cachedAt = cachedAt
    }

    // MARK: - Coverage
    //
    // How much has actually been analysed, said plainly. Every proposal on the dashboard is
    // computed from this window and no more, so a screen that implied whole-mailbox coverage
    // would be misrepresenting the one thing the user needs in order to weigh a suggestion.

    /// "1,000 messages loaded".
    var coverageHeadline: String {
        "\(loadedMessageCount.formatted()) \(loadedMessageCount == 1 ? "message" : "messages") loaded"
    }

    /// Whether the provider has mail beyond what has been read.
    var hasUnreadDepth: Bool { hasMoreMessages }

    /// What the loaded window does and does not cover, in one sentence.
    ///
    /// Never claims completeness unless the provider actually ran out of pages, and never
    /// calls a scope "your mailbox" when it was a single category.
    var coverageDetail: String {
        if hasMoreMessages {
            return "More messages are available in \(scope.possessivePhrase). Everything on this screen describes the \(loadedMessageCount.formatted()) loaded so far."
        }
        return "That is everything InboxSweep could list from \(scope.possessivePhrase). \(scope.coverageCaveat)"
    }

    /// The progress line shown while pages are still arriving.
    var loadProgressDescription: String? {
        guard isLoadingMore else { return nil }
        return "\(coverageHeadline) from \(loadedPageCount) \(loadedPageCount == 1 ? "page" : "pages")…"
    }

    /// Whether what is on screen was restored from disk rather than read this launch.
    var isRestoredFromCache: Bool { cachedAt != nil }

    /// Number of distinct senders in the loaded window.
    var senderCount: Int { senders.count }

    /// Whether the load succeeded but found nothing.
    var isEmpty: Bool { loadedMessageCount == 0 }

    /// The oldest message date in the window: how far back the app has actually looked.
    var oldestLoadedDate: Date? {
        senders.map(\.oldestLoadedReceivedAt).min()
    }

    /// Total unread messages across the loaded window.
    var unreadMessageCount: Int {
        senders.reduce(0) { $0 + $1.unreadCount }
    }

    // MARK: - Proposals

    /// The proposal for a sender, when one has been computed.
    ///
    /// Optional rather than a defaulted value: a missing proposal is a bug worth seeing in the
    /// UI as an absence, not one papered over with an invented "keep".
    func proposal(for senderKey: SenderSummary.ID) -> SenderCleanupProposal? {
        proposals[senderKey]
    }

    /// The senders a filter admits, in the current sort order.
    ///
    /// Senders with no proposal are shown only by ``ProposalFilter/all``, so a narrowing
    /// filter can never quietly include something the rules never looked at.
    func senders(matching filter: ProposalFilter) -> [SenderSummary] {
        guard filter != .all else { return senders }
        return senders.filter { sender in
            proposals[sender.id].map(filter.matches) ?? false
        }
    }

    /// How many senders a filter admits, for the count beside a filter control.
    func senderCount(matching filter: ProposalFilter) -> Int {
        filter == .all ? senders.count : senders(matching: filter).count
    }

    /// What the loaded window covers, for anything that reports numbers derived from it.
    func planWindow() -> CleanupPlanWindow {
        CleanupPlanWindow(
            loadedMessageCount: loadedMessageCount,
            hasMoreBeyondWindow: hasMoreMessages,
            scope: scope
        )
    }

    func replacingSortOrder(_ newOrder: SenderSortOrder) -> InboxSnapshot {
        InboxSnapshot(
            account: account,
            loadedMessageCount: loadedMessageCount,
            senders: SenderAggregator.sort(senders, by: newOrder),
            sortOrder: newOrder,
            scope: scope,
            hasMoreMessages: hasMoreMessages,
            isLoadingMore: isLoadingMore,
            loadedPageCount: loadedPageCount,
            proposals: proposals,
            cachedAt: cachedAt
        )
    }

    func settingLoadingMore(_ isLoadingMore: Bool) -> InboxSnapshot {
        InboxSnapshot(
            account: account,
            loadedMessageCount: loadedMessageCount,
            senders: senders,
            sortOrder: sortOrder,
            scope: scope,
            hasMoreMessages: hasMoreMessages,
            isLoadingMore: isLoadingMore,
            loadedPageCount: loadedPageCount,
            proposals: proposals,
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

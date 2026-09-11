import Foundation
import Observation

/// Owns the app's connection to a mail provider and the window of mail loaded from it.
///
/// This is the only type the views talk to, and the only place ``MailProviderError`` becomes a
/// screen. It is `@MainActor` because it is view state; the work it drives — network requests,
/// normalization, aggregation — happens off the main actor inside the provider and in a
/// detached task, so a slow mailbox never freezes the window.
@MainActor
@Observable
final class InboxSessionModel {

    /// What the window should currently show.
    private(set) var state: InboxSessionState = .signedOut

    /// How the sender list is ordered. Changing it re-sorts what is already loaded and never
    /// re-fetches, so switching order is instant and costs no quota.
    var sortOrder: SenderSortOrder {
        didSet {
            guard sortOrder != oldValue, case .loaded(let snapshot) = state else { return }
            state = .loaded(snapshot.replacingSortOrder(sortOrder))
        }
    }

    private let provider: any MailProvider
    private let cache: any InboxCacheStoring
    private let fetchRequest: MailFetchRequest
    private let now: @Sendable () -> Date

    /// The loaded window, kept so that re-sorting and paging do not need a round trip.
    private var messages: [MailMessage] = []
    private var nextPageToken: MailPageToken?
    private var activeTask: Task<Void, Never>?

    /// When the loaded window was written to the cache, or `nil` when it came from the
    /// provider during this launch. Shown in the header so a window restored from disk is
    /// never mistaken for a fresh read of the mailbox.
    private var restoredFromCacheAt: Date?

    init(
        provider: any MailProvider,
        cache: any InboxCacheStoring = EphemeralInboxCache(),
        fetchRequest: MailFetchRequest = MailFetchRequest(),
        sortOrder: SenderSortOrder = .messageVolume,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.cache = cache
        self.fetchRequest = fetchRequest
        self.sortOrder = sortOrder
        self.now = now
    }

    /// The provider's display name, for UI copy.
    var providerDisplayName: String { provider.displayName }

    /// The connected account, when there is one.
    var account: MailAccount? {
        switch state {
        case .loading(let account): account
        case .loaded(let snapshot): snapshot.account
        case .failed(_, let account): account
        case .signedOut, .restoring, .connecting: nil
        }
    }

    // MARK: - Operations
    //
    // Each returns its `Task` so callers can await completion. Views ignore the result; tests
    // await it, which is what makes these deterministic to test without polling or sleeping.

    /// Re-establishes a previously authorized connection, if one was stored.
    ///
    /// Silent by design: finding nothing stored is the normal first-launch case and lands on
    /// the signed-out screen rather than an error.
    ///
    /// When a cached window for the restored account is available it is shown instead of
    /// refetching, so a relaunch costs no Gmail quota and no waiting. **Reload** is how the
    /// user asks for fresh mail, and the header says how old the shown window is.
    @discardableResult
    func restore() -> Task<Void, Never> {
        run { [self] in
            state = .restoring
            do {
                let connection = try await provider.restoreConnection()
                guard let account = connection.account else {
                    state = .signedOut
                    return
                }
                if await adoptCachedWindow(for: account) { return }
                await loadFirstPage(for: account)
            } catch {
                let providerError = MailProviderError.wrapping(error)
                // A stored grant that no longer works is not something to alarm the user
                // about at launch; it just means they need to connect again.
                state = providerError.requiresReauthentication ? .signedOut : .failed(providerError, account: nil)
            }
        }
    }

    /// Starts an interactive sign-in and, on success, loads the first window.
    @discardableResult
    func connect() -> Task<Void, Never> {
        run { [self] in
            state = .connecting
            do {
                let account = try await provider.connect()
                await loadFirstPage(for: account)
            } catch {
                let providerError = MailProviderError.wrapping(error)
                // Backing out of Google's sign-in sheet is a decision, not a failure.
                state = providerError == .cancelled ? .signedOut : .failed(providerError, account: nil)
            }
        }
    }

    /// Discards the loaded window and fetches it again.
    @discardableResult
    func reload() -> Task<Void, Never> {
        guard let account else { return .alreadyFinished }
        return run { [self] in await loadFirstPage(for: account) }
    }

    /// Fetches the next page and merges it into the current window.
    @discardableResult
    func loadMore() -> Task<Void, Never> {
        guard case .loaded(let snapshot) = state,
              let pageToken = nextPageToken,
              !snapshot.isLoadingMore
        else { return .alreadyFinished }

        return run { [self] in
            state = .loaded(snapshot.settingLoadingMore(true))
            do {
                let page = try await provider.fetchMessages(fetchRequest.nextPage(after: pageToken))
                try Task.checkCancellation()
                // Merged rather than appended: Gmail can list a message on two consecutive
                // pages, and counting it twice would overstate the sender it came from.
                messages = MailMessageWindow.merging(messages, with: page.messages)
                nextPageToken = page.nextPageToken
                await publishSnapshot(for: snapshot.account)
            } catch {
                // The already-loaded window is still valid and still useful, so a failed
                // *additional* page returns to it rather than throwing it away.
                state = .loaded(snapshot.settingLoadingMore(false))
                let providerError = MailProviderError.wrapping(error)
                if providerError.requiresReauthentication {
                    reset()
                    state = .failed(providerError, account: snapshot.account)
                }
            }
        }
    }

    /// Cancels whatever is in flight.
    func cancel() {
        activeTask?.cancel()
    }

    /// Signs out and returns to the starting state.
    ///
    /// Signing out also deletes the cached window. Disconnecting is the user saying they are
    /// done, and leaving their mail's metadata on disk afterwards would be the opposite of
    /// what they asked for.
    @discardableResult
    func disconnect() -> Task<Void, Never> {
        let connectedAccount = account
        activeTask?.cancel()
        return run { [self] in
            await provider.disconnect()
            if let connectedAccount { await cache.clear(for: connectedAccount) }
            reset()
            state = .signedOut
        }
    }

    // MARK: - Loaded window

    /// The loaded messages from one sender, newest first.
    ///
    /// Answers the question the aggregate row raises — "which messages are these?" — from the
    /// window already in memory, so opening a sender costs no request.
    func loadedMessages(forSenderKey key: SenderSummary.ID) -> [MailMessage] {
        messages
            .filter { $0.sender.groupingKey == key }
            // Ties break on ID so the list is stable between identical loads, exactly as the
            // sender list is.
            .sorted { $0.receivedAt == $1.receivedAt ? $0.id.rawValue < $1.id.rawValue : $0.receivedAt > $1.receivedAt }
    }

    // MARK: - Cleanup previews

    /// The proposal for a sender in the loaded window, if one has been computed.
    func proposal(forSenderKey key: SenderSummary.ID) -> SenderCleanupProposal? {
        state.snapshot?.proposal(for: key)
    }

    /// Previews what `requests` would reach, without contacting the provider.
    ///
    /// Synchronous and local on purpose. Every message this reads is already in memory, so
    /// there is no request to make, nothing to await, and no code path from here to Gmail —
    /// which is the property `SafetyBoundaryTests` pins down.
    func cleanupPlan(for requests: [CleanupPlanRequest]) -> CleanupPlan {
        guard case .loaded(let snapshot) = state else {
            return .empty(window: CleanupPlanWindow(loadedMessageCount: 0, hasMoreBeyondWindow: false, scope: fetchRequest.scope))
        }

        var messagesBySender: [SenderSummary.ID: [MailMessage]] = [:]
        for message in messages {
            messagesBySender[message.sender.groupingKey, default: []].append(message)
        }

        return CleanupPlanner.plan(
            requests: requests,
            messagesBySender: messagesBySender,
            proposals: snapshot.proposals,
            window: snapshot.planWindow(scope: fetchRequest.scope),
            referenceDate: now()
        )
    }

    // MARK: - Internals

    /// Serializes operations: starting a new one cancels whatever was running.
    private func run(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        activeTask?.cancel()
        let task = Task { @MainActor in await operation() }
        activeTask = task
        return task
    }

    /// Shows the stored window for `account`, if there is a usable one.
    ///
    /// Returns whether it did, which is what lets ``restore()`` skip the fetch entirely.
    private func adoptCachedWindow(for account: MailAccount) async -> Bool {
        guard let cached = await cache.load(for: account), !cached.messages.isEmpty else { return false }
        guard !Task.isCancelled else { return false }

        messages = cached.messages
        nextPageToken = cached.nextPageToken
        restoredFromCacheAt = cached.savedAt

        // Summaries are derived data stored beside their source. Trust them when they still
        // add up to the stored messages, and rebuild them when they do not, rather than
        // showing counts that disagree with the window they claim to describe.
        let senders = cached.summariesMatchMessages
            ? SenderAggregator.sort(cached.senders, by: sortOrder)
            : await aggregate(cached.messages)

        // Proposals are never stored, only recomputed. That is what makes a rules change take
        // effect on the next launch instead of leaving last week's verdicts on screen.
        let proposals = await makeProposals(senders: senders, messages: messages)

        state = .loaded(
            InboxSnapshot(
                account: account,
                loadedMessageCount: messages.count,
                senders: senders,
                sortOrder: sortOrder,
                hasMoreMessages: nextPageToken != nil,
                isLoadingMore: false,
                proposals: proposals,
                cachedAt: cached.savedAt
            )
        )
        return true
    }

    private func loadFirstPage(for account: MailAccount) async {
        reset()
        state = .loading(account)

        do {
            let page = try await provider.fetchMessages(fetchRequest)
            try Task.checkCancellation()
            messages = MailMessageWindow.deduplicated(page.messages)
            nextPageToken = page.nextPageToken
            await publishSnapshot(for: account)
        } catch {
            let providerError = MailProviderError.wrapping(error)
            if providerError.requiresReauthentication { reset() }
            state = .failed(providerError, account: providerError.requiresReauthentication ? nil : account)
        }
    }

    /// Aggregates off the main actor, publishes the result, and stores it for the next launch.
    ///
    /// Aggregation is linear in the loaded window, which stays small enough to be quick — but
    /// it grows with every page, so it is kept off the actor that draws the window.
    private func publishSnapshot(for account: MailAccount) async {
        let senders = await aggregate(messages)
        let proposals = await makeProposals(senders: senders, messages: messages)

        guard !Task.isCancelled else { return }

        state = .loaded(
            InboxSnapshot(
                account: account,
                loadedMessageCount: messages.count,
                senders: senders,
                sortOrder: sortOrder,
                hasMoreMessages: nextPageToken != nil,
                isLoadingMore: false,
                proposals: proposals,
                // Sticky: appending a page to a restored window does not make the pages
                // underneath it fresh, and only a full reload clears this.
                cachedAt: restoredFromCacheAt
            )
        )

        await cache.save(
            CachedInbox(
                account: account,
                messages: messages,
                senders: senders,
                nextPageToken: nextPageToken,
                savedAt: now()
            )
        )
    }

    private func aggregate(_ messages: [MailMessage]) async -> [SenderSummary] {
        let sortOrder = sortOrder
        return await Task.detached(priority: .userInitiated) {
            SenderAggregator.aggregate(messages, sortedBy: sortOrder)
        }.value
    }

    /// Evaluates every sender against the proposal rules, off the main actor.
    ///
    /// Kept off the actor that draws the window for the same reason aggregation is: it is
    /// linear in the loaded window, and the window grows with every page.
    private func makeProposals(
        senders: [SenderSummary],
        messages: [MailMessage]
    ) async -> [SenderSummary.ID: SenderCleanupProposal] {
        await Task.detached(priority: .userInitiated) {
            CleanupProposalEngine.evaluate(summaries: senders, messages: messages)
        }.value
    }

    private func reset() {
        messages = []
        nextPageToken = nil
        restoredFromCacheAt = nil
    }
}

private extension Task where Success == Void, Failure == Never {
    /// A task that has nothing to do, returned when an operation is not applicable.
    ///
    /// Callers still get something to await, and — unlike routing the no-op through `run` —
    /// requesting an inapplicable operation does not cancel whatever is already running.
    static var alreadyFinished: Task<Void, Never> { Task {} }
}

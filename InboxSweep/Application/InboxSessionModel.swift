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

    /// Something worth telling the user that is not an error screen — a sign-in that could not
    /// be restored, or one that could not be saved.
    ///
    /// Cleared whenever a new connect or restore begins, so a notice never outlives the
    /// situation that produced it.
    private(set) var notice: SessionNotice?

    /// How the sender list is ordered. Changing it re-sorts what is already loaded and never
    /// re-fetches, so switching order is instant and costs no quota.
    var sortOrder: SenderSortOrder {
        didSet {
            guard sortOrder != oldValue, case .loaded(let snapshot) = state else { return }
            state = .loaded(snapshot.replacingSortOrder(sortOrder))
        }
    }

    /// Which part of the mailbox is being read.
    ///
    /// Changing it discards the loaded window and reads the new scope, because a window that
    /// mixed scopes would make every count on the dashboard describe something the user could
    /// not name. Assigning the same value does nothing.
    var scope: MailboxScope {
        didSet {
            guard scope != oldValue else { return }
            guard let account else { return }
            _ = run { [self] in await loadFirstPage(for: account) }
        }
    }

    /// How much of the scope a deep load reads.
    ///
    /// A preference, not an action: setting it changes what ``loadToDepth()`` will do and never
    /// starts a fetch by itself, so a stray click on a picker cannot cost two thousand
    /// requests.
    var loadDepth: MailboxLoadDepth

    /// The saved preview choices for the connected account, checked against the window on
    /// screen, or `nil` when there are none.
    ///
    /// Read-only from the outside and never acted on: restoring a plan re-opens a preview.
    /// There is nothing in the app that could carry one out.
    private(set) var savedPlan: RestoredCleanupPlan?

    // MARK: - Mutation state
    //
    // The app can change exactly one thing about a mailbox, and these three properties are the
    // whole of what the UI needs to know about it: whether it is allowed, what is happening,
    // and whether the last thing that happened can be taken back.

    /// Whether archiving is available for the connected account.
    ///
    /// Refreshed whenever a window is published, because it is a fact about the *grant* and the
    /// grant can change under the app — an upgrade, a withdrawal from the Google Account, a
    /// different account signing in. Starts at ``MailMutationCapability/unsupported`` so a
    /// session that has never connected offers nothing.
    private(set) var archiveCapability: MailMutationCapability = .unsupported

    /// The archive or undo currently in flight, or the result of the last one.
    ///
    /// `nil` means nothing has been attempted, or the user has dismissed the result. While this
    /// is running a second mutation is refused outright — which is the guard that makes a double
    /// click one mutation rather than two, independently of whether the button was disabled in
    /// time.
    private(set) var mutationActivity: MessageMutationActivity?

    /// The archive that can still be taken back, if any.
    ///
    /// **Durable.** Unlike the previous interval's in-memory offer, this is read back out of the
    /// local transaction file, so it survives dismissing the sheet, navigating away, reloading
    /// the window, and quitting the app. See ``MailMutationTransaction`` for the lifecycle and
    /// ``restoreUndoOffer(for:)`` for what has to be true before it is offered again.
    private(set) var undoableArchive: MailMutationTransaction?

    private let provider: any MailProvider
    private let cache: any InboxCacheStoring
    private let planStore: any CleanupPlanStoring
    private let mutationRecords: any MailMutationRecording
    private let now: @Sendable () -> Date

    /// The mutation boundary, when the provider has one.
    ///
    /// Taken from the provider rather than injected beside it, so the object that performs an
    /// archive is always the one holding the authorization the window was read with. A `nil`
    /// here is not a disabled feature — it is the absence of any code path to a mutation, which
    /// is what the synthetic mailbox gets.
    private let archiver: (any MailMessageArchiving)?

    /// The loaded window, kept so that re-sorting and paging do not need a round trip.
    private var messages: [MailMessage] = []

    private var nextPageToken: MailPageToken?
    private var activeTask: Task<Void, Never>?

    /// The in-flight mutation, held separately from ``activeTask``.
    ///
    /// Separate because ``cancel()`` exists for loads: a user who cancels a slow deep load has
    /// not asked to abandon an archive that is already with Gmail, and abandoning it would be
    /// the app giving up on finding out whether the mailbox changed.
    private var mutationTask: Task<Void, Never>?

    /// How many pages have been read into the current window, for the progress line.
    private var loadedPageCount = 0

    /// The saved plan as it was written, before being checked against the current window.
    ///
    /// Kept separately from ``savedPlan`` so staleness can be re-evaluated after every page
    /// without re-reading the file — a plan that was fine over 250 messages becomes stale the
    /// moment a deep load reaches 2,500, and the user finds that out as it happens.
    private var storedPlan: SavedCleanupPlan?

    /// The operation identifiers that have already been sent to the mutation boundary.
    ///
    /// One confirmation is one operation, and this is what makes that true beyond the window in
    /// which ``mutationActivity`` still describes it. The activity can be dismissed and the sheet
    /// that produced it can stay on screen; an identifier in here cannot be un-executed.
    ///
    /// Session-lifetime rather than persisted, because it guards a *frozen snapshot*, and a
    /// snapshot does not survive a relaunch either — there is nothing left after a quit that
    /// could be submitted twice.
    private var executedSelectionIDs: Set<UUID> = []

    /// When the loaded window was written to the cache, or `nil` when it came from the
    /// provider during this launch. Shown in the header so a window restored from disk is
    /// never mistaken for a fresh read of the mailbox.
    private var restoredFromCacheAt: Date?

    init(
        provider: any MailProvider,
        cache: any InboxCacheStoring = EphemeralInboxCache(),
        planStore: any CleanupPlanStoring = EphemeralCleanupPlanStore(),
        mutationRecords: any MailMutationRecording = EphemeralMutationRecordStore(),
        fetchRequest: MailFetchRequest = MailFetchRequest(),
        loadDepth: MailboxLoadDepth = .firstPage,
        sortOrder: SenderSortOrder = .messageVolume,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.archiver = provider.messageArchiver
        self.cache = cache
        self.planStore = planStore
        self.mutationRecords = mutationRecords
        self.firstPageRequest = fetchRequest
        self.scope = fetchRequest.scope
        self.loadDepth = loadDepth
        self.sortOrder = sortOrder
        self.now = now
    }

    /// The shape of the *first* page: its size, and the scope a new session starts on.
    ///
    /// Kept because callers — previews, the sample mailbox, tests — configure a first-page size
    /// that is not the app's default. The scope on it is only the starting value; ``scope`` is
    /// what a load actually uses.
    private let firstPageRequest: MailFetchRequest

    /// The request for the first page of the current scope.
    private var currentFirstPageRequest: MailFetchRequest {
        MailFetchRequest(limit: firstPageRequest.limit, scope: scope)
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
    /// Finding nothing stored is the normal first-launch case and lands silently on the
    /// signed-out screen. Finding something that *cannot be used* lands there too — but with a
    /// ``notice`` saying so, because a Keychain refusal and a first launch produce the same
    /// screen and are not remotely the same thing.
    ///
    /// When a cached window for the restored account is available it is shown instead of
    /// refetching, so a relaunch costs no Gmail quota and no waiting. **Reload** is how the
    /// user asks for fresh mail, and the header says how old the shown window is. A restore
    /// that failed shows no cache at all: mail is only ever displayed alongside the
    /// authenticated account it belongs to.
    @discardableResult
    func restore() -> Task<Void, Never> {
        run { [self] in
            state = .restoring
            notice = nil

            switch await provider.restoreConnection() {
            case .noStoredCredentials:
                state = .signedOut

            case .restored(let account):
                notice = await provider.storedAuthorizationState().warning.map(SessionNotice.notPersisted)
                if await adoptCachedWindow(for: account) { return }
                await loadFirstPage(for: account)

            case .unusable(let failure):
                reset()
                if let restoreNotice = SessionNotice.forRestoreFailure(failure) {
                    notice = restoreNotice
                    state = .signedOut
                } else {
                    // A provider outage is worth an error screen with a retry, not a request
                    // to sign in again over something that is nobody's authorization problem.
                    state = .failed(failure.providerError, account: nil)
                }
            }
        }
    }

    /// Starts an interactive sign-in and, on success, loads the first window.
    @discardableResult
    func connect() -> Task<Void, Never> {
        run { [self] in
            state = .connecting
            notice = nil
            do {
                let account = try await provider.connect()
                // Asked straight after signing in, while it is still actionable: a sign-in
                // that could not be saved is not a failure, but the user is about to rely on
                // it surviving a relaunch.
                notice = await provider.storedAuthorizationState().warning.map(SessionNotice.notPersisted)
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
        loadPages(upToTotal: messages.count + loadDepth.pageSize, pageSize: loadDepth.pageSize)
    }

    /// Keeps reading pages until ``loadDepth`` is satisfied, the provider runs out, or the
    /// user cancels.
    ///
    /// The window grows page by page and the dashboard is republished after each one, so the
    /// user watches the message count climb rather than staring at a spinner — and so the
    /// proposals on screen reflect the evidence loaded *so far* rather than appearing all at
    /// once at the end.
    @discardableResult
    func loadToDepth() -> Task<Void, Never> {
        loadPages(upToTotal: loadDepth.messageLimit, pageSize: loadDepth.pageSize)
    }

    /// Reads pages until the window holds `upToTotal` messages or the provider is exhausted.
    ///
    /// Bounded three ways, all of them on purpose: by the target count, by
    /// ``MailboxLoadDepth/safetyLimit``, and by a page budget that stops a provider which keeps
    /// handing back a cursor and no messages from looping forever.
    private func loadPages(upToTotal: Int, pageSize: Int) -> Task<Void, Never> {
        guard case .loaded(let startingSnapshot) = state,
              nextPageToken != nil,
              !startingSnapshot.isLoadingMore
        else { return .alreadyFinished }

        let target = min(upToTotal, MailboxLoadDepth.safetyLimit)
        guard messages.count < target else { return .alreadyFinished }

        return run { [self] in
            let account = startingSnapshot.account
            state = .loaded(startingSnapshot.settingLoadingMore(true))

            // One more page than the target could possibly need. A provider that returns an
            // empty page with a cursor is unusual, but "unusual" is not a reason to let a
            // loop run unbounded against somebody's account.
            let pageBudget = Int((Double(target) / Double(pageSize)).rounded(.up)) + 1

            for _ in 0..<pageBudget {
                guard messages.count < target, let pageToken = nextPageToken else { break }
                guard !Task.isCancelled else { break }

                do {
                    let page = try await provider.fetchMessages(
                        MailFetchRequest(limit: pageSize, pageToken: pageToken, scope: scope)
                    )
                    try Task.checkCancellation()

                    let added = merge(page.messages)
                    nextPageToken = page.nextPageToken
                    loadedPageCount += 1

                    // Publish even when a page was entirely duplicates: the cursor moved, and
                    // a dashboard that froze mid-load would look like a hang.
                    await publishSnapshot(
                        for: account,
                        isLoadingMore: messages.count < target && nextPageToken != nil,
                        persist: false
                    )

                    if added == 0, page.messages.isEmpty { break }
                } catch is CancellationError {
                    break
                } catch {
                    // The already-loaded window is still valid and still useful, so a failed
                    // *additional* page returns to it rather than throwing it away.
                    let providerError = MailProviderError.wrapping(error)
                    if providerError.requiresReauthentication {
                        reset()
                        state = .failed(providerError, account: account)
                        return
                    }
                    break
                }
            }

            // A cancelled deep load keeps every page it managed to read; the alternative is
            // throwing away work the user already waited for.
            await publishSnapshot(for: account, isLoadingMore: false, persist: true)
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
            let outcome = await provider.disconnect()
            if let connectedAccount {
                await cache.clear(for: connectedAccount)
                // Disconnecting is the user saying they are done. Leaving a list of their
                // senders on disk afterwards would be the opposite of what they asked for.
                await planStore.clear(for: connectedAccount)
                // The record of what was archived goes too. It names messages in a mailbox the
                // app no longer has permission to look at, so keeping it would be keeping a
                // list about somebody's mail for nobody's benefit.
                await mutationRecords.clear(for: connectedAccount)
            }
            reset()
            state = .signedOut
            // A sign-out that did not fully take is the one thing about disconnecting worth
            // interrupting the user for: the window says signed out either way, and only this
            // says whether the saved sign-in actually went with it.
            notice = SessionNotice.forDisconnectOutcome(outcome)
        }
    }

    // MARK: - Loaded window

    /// The loaded messages from one sender, newest first.
    ///
    /// Answers the question the aggregate row raises — "which messages are these?" — from the
    /// window already in memory, so opening a sender costs no request.
    func loadedMessages(forSenderKey key: SenderSummary.ID) -> [MailMessage] {
        messagesInScope
            .filter { $0.sender.groupingKey == key }
            // Ties break on ID so the list is stable between identical loads, exactly as the
            // sender list is.
            .sorted { $0.receivedAt == $1.receivedAt ? $0.id.rawValue < $1.id.rawValue : $0.receivedAt > $1.receivedAt }
    }

    // MARK: - Saved planning state

    /// Remembers the senders and actions currently chosen in the preview.
    ///
    /// Stores the *choosing* and nothing derived from it: no proposal, no reason, no count of
    /// what would be affected. Those are recomputed from the loaded window every launch, so a
    /// saved plan cannot bring a stale verdict back onto the screen.
    ///
    /// Saving does not schedule anything. There is no execution path in this app for a plan to
    /// be executed by.
    @discardableResult
    func savePlan(_ selections: [SavedCleanupSelection]) -> Task<Void, Never> {
        guard case .loaded(let snapshot) = state else { return .alreadyFinished }
        guard !selections.isEmpty else { return discardSavedPlan() }

        let plan = SavedCleanupPlan(
            accountAddress: snapshot.account.emailAddress.address,
            scope: snapshot.scope,
            selections: selections,
            loadedMessageCount: snapshot.loadedMessageCount,
            savedAt: now()
        )

        // Published against the window it was just saved against, so it starts out un-stale
        // rather than waiting for a reload to be evaluated.
        storedPlan = plan
        savedPlan = plan.restored(into: snapshot)

        return Task { [planStore] in await planStore.save(plan) }
    }

    /// Forgets the saved choices for the connected account.
    @discardableResult
    func discardSavedPlan() -> Task<Void, Never> {
        storedPlan = nil
        savedPlan = nil
        guard let account else { return .alreadyFinished }
        return Task { [planStore] in await planStore.clear(for: account) }
    }

    // MARK: - Message review

    /// The loaded messages from one sender, as the review screen shows them.
    ///
    /// Answers three questions at once: which messages are these, which of them are protected
    /// on their own merits, and — when `action` is given — which a previewed cleanup would
    /// reach. All three from the window already in memory, so opening a review costs no
    /// request and cannot fetch a body there is no field to hold.
    ///
    /// - Parameters:
    ///   - key: The sender's grouping key.
    ///   - action: The action to show membership for, or `nil` for no plan at all.
    ///   - sortOrder: How to order the result.
    func reviewedMessages(
        forSenderKey key: SenderSummary.ID,
        under action: PlannedCleanupAction? = nil,
        sortedBy sortOrder: MessageReviewSortOrder = .newestFirst
    ) -> [ReviewedMessage] {
        let senderMessages = messagesInScope.filter { $0.sender.groupingKey == key }
        guard !senderMessages.isEmpty else { return [] }

        let membership = action.map {
            CleanupPlanner.membership(for: senderMessages, action: $0, referenceDate: now())
        }

        return sortOrder.sort(
            senderMessages.map { message in
                ReviewedMessage(
                    message: message,
                    protectionReason: SenderProtection.protectionReason(for: message),
                    membership: membership?[message.id]
                )
            }
        )
    }

    // MARK: - Archiving messages the user selected
    //
    // The app's only write. Everything here is scoped to a set of messages the user picked one
    // by one and confirmed as a list: there is no sender form, no "everything matching" form,
    // and nothing that a proposal, a saved plan, or a dry run can reach. A recommendation can
    // lead the user to the review screen, and can offer to *fill in* a selection they then
    // inspect and edit, and it stops there.

    /// Whether this session could archive at all, ignoring whether permission has been granted.
    ///
    /// Distinguishes "the sample mailbox cannot be changed" from "your grant does not cover it
    /// yet", so the UI offers a reconnect only where reconnecting would help.
    var canOfferArchiving: Bool { archiveCapability != .unsupported }

    /// Whether a mutation is in flight right now.
    var isMutating: Bool { mutationActivity?.isRunning == true }

    /// Whether this specific message could be included in an archive right now.
    ///
    /// Everything a confirmation depends on, checked before the action is offered rather than
    /// after it is pressed: a loaded window, that message in it, a granted permission, and
    /// nothing already running.
    func canArchive(messageID: MailMessageID) -> Bool {
        archiveCapability.isGranted
            && !isMutating
            && state.snapshot != nil
            && messagesInScope.contains { $0.id == messageID }
    }

    /// Asks the user for the Gmail permission archiving needs.
    ///
    /// Separate from archiving on purpose: granting a permission and changing a mailbox are two
    /// decisions, and rolling them into one action would mean the click that consented was also
    /// the click that archived.
    @discardableResult
    func requestArchivePermission() -> Task<Void, Never> {
        guard let archiver, archiveCapability.isUpgradable, !isMutating else { return .alreadyFinished }

        return runMutation { [self] in
            do {
                let granted = try await archiver.authorizeArchiving()
                notice = granted.isGranted ? nil : SessionNotice.archivePermissionDeclined
            } catch {
                let mutationError = MailMutationError.wrapping(error)
                // A declined upgrade leaves the read-only grant exactly as it was, and the
                // session carries on reading. A cancelled one is not worth a notice at all.
                notice = mutationError == .cancelled ? nil : SessionNotice.archivePermissionDeclined
            }

            // Asked of the provider rather than taken from the return value, and then
            // republished — both halves matter.
            //
            // Asking again is the more honest of the two: the provider is the thing that holds
            // the grant, and a capability re-derived from it cannot disagree with what the next
            // archive attempt will actually find.
            //
            // Republishing is what makes the change *visible*. A granted permission used to
            // move nothing but this one scalar, and the screen that offers the action is a
            // sheet whose every other value comes from the snapshot — so the button kept
            // offering to request a permission the user had already granted until the sheet was
            // closed and reopened. Observed on a real account. Every other operation in this
            // session ends by republishing; this one had no business being the exception.
            archiveCapability = await currentArchiveCapability()
            if case .loaded(let snapshot) = state {
                // `persist: false`: no mail changed, so the cache file would be rewritten
                // byte-for-byte identical.
                await publishSnapshot(for: snapshot.account, isLoadingMore: false, persist: false)
                // A grant that has just arrived can make a stored transaction undoable again.
                await restoreUndoOffer(for: snapshot.account)
            }
        }
    }

    // MARK: - Building a selection

    /// The messages a proposal-driven convenience action may fill in for a sender.
    ///
    /// This is the **only** place the app turns a recommendation into a list of identifiers, and
    /// two properties make that safe to do:
    ///
    /// - it performs no write and starts nothing — it returns identifiers for a checkbox column,
    ///   and the user still has to inspect them, keep or remove them, open a confirmation, and
    ///   press a button;
    /// - it never includes a protected message. The planner already holds protected messages
    ///   back, and this filters on protection a second time so the guarantee does not depend on
    ///   the planner continuing to order its two filters the way it does today.
    ///
    /// A user who wants a protected message archived can still tick it themselves, and the
    /// confirmation says so in as many words. The distinction this draws is between *the app
    /// choosing* and *the user choosing*: the app never chooses a message somebody's own mailbox
    /// has marked as worth keeping.
    func preselectableMessageIDs(
        forSenderKey key: SenderSummary.ID,
        under action: PlannedCleanupAction
    ) -> [MailMessageID] {
        senderReviewCandidates(forSenderKey: key, under: action).messageIDs
    }

    /// What a sender-level *Review messages to archive…* opens the review screen with.
    ///
    /// The same identifiers ``preselectableMessageIDs(forSenderKey:under:)`` returns, plus the
    /// counts needed to say *why* — how many the action's scope missed, how many protection held
    /// back, and, when the answer is none at all, which of those it was.
    ///
    /// Everything the safety note on ``preselectableMessageIDs(forSenderKey:under:)`` says applies
    /// unchanged, because this is where that method now gets its answer. Deriving this **performs
    /// no write and starts nothing**: it filters ``reviewedMessages(forSenderKey:under:sortedBy:)``,
    /// which is itself a pass over the window already in memory. There is no request, no plan
    /// object handed to anything, and nothing remembered.
    ///
    /// Recomputed on every call rather than cached, so a deeper load or a reload between opening
    /// a sender and opening its review produces candidates for the window that is actually there.
    func senderReviewCandidates(
        forSenderKey key: SenderSummary.ID,
        under action: PlannedCleanupAction
    ) -> SenderReviewCandidates {
        SenderReviewCandidates.derive(
            from: reviewedMessages(forSenderKey: key, under: action),
            senderKey: key,
            under: action
        )
    }

    /// Freezes a set of chosen messages into the exact thing a confirmation will show.
    ///
    /// Pure and local: it reads the window already in memory and returns a value. **Nothing is
    /// sent, nothing is scheduled, and nothing is remembered** — building a snapshot the user
    /// then abandons costs one allocation.
    ///
    /// Returns `nil`, rather than a narrowed set, when any chosen identifier is not currently a
    /// loaded message of `key`'s sender. Silently dropping the strays would mean opening a
    /// confirmation for a different set than the one the user ticked, which is precisely what
    /// freezing exists to prevent. The caller's recovery is to reload and choose again.
    func makeArchiveSelection(
        forSenderKey key: SenderSummary.ID,
        messageIDs: some Collection<MailMessageID>
    ) -> ArchiveSelectionSnapshot? {
        guard case .loaded(let snapshot) = state, !messageIDs.isEmpty else { return nil }

        let reviewed = reviewedMessages(forSenderKey: key)
        let byID = Dictionary(uniqueKeysWithValues: reviewed.map { ($0.id, $0) })

        // Ordered by the review list rather than by the order the user happened to tick rows,
        // so the confirmation reads top-to-bottom like the screen it came from.
        let chosen = Set(messageIDs)
        let selected = reviewed.filter { chosen.contains($0.id) }
        guard selected.count == chosen.count, chosen.allSatisfy({ byID[$0] != nil }) else { return nil }

        return ArchiveSelectionSnapshot(
            accountAddress: snapshot.account.emailAddress.address,
            senderKey: key,
            senderDisplayValue: snapshot.senders.first { $0.id == key }?.sender.displayValue ?? key,
            scope: scope,
            messages: selected.map {
                ArchiveSelectionSnapshot.SelectedMessage(
                    id: $0.id,
                    subject: $0.message.subject,
                    receivedAt: $0.message.receivedAt,
                    protectionReason: $0.protectionReason
                )
            },
            frozenAt: now()
        )
    }

    /// Whether the frozen set could be archived right now, without sending anything to find out.
    ///
    /// The cheap half of the validation the execution path performs. It cannot check the
    /// authenticated account — that question can only be asked of the provider, and only
    /// asynchronously — so it is a guard for a button's enabled state, never a substitute for
    /// the re-validation in ``archiveSelection(_:)``.
    func canArchive(_ selection: ArchiveSelectionSnapshot) -> Bool {
        validateAgainstLoadedWindow(selection) == nil
    }

    // MARK: - Executing a selection

    /// Archives exactly the frozen set, after the user has confirmed it.
    ///
    /// This method performs no confirming of its own — by the time it is called the user has
    /// seen every message in the set and pressed the confirming button. What it does do is
    /// **refuse**: every precondition is re-checked here against the state as it is *now*,
    /// because the window can reload and the account can change between reviewing a set and
    /// confirming it. A set that no longer matches the window is not narrowed and not partially
    /// executed; it is refused, and the user reviews again.
    ///
    /// Local state is reconciled only for the messages Gmail confirmed. There is no optimistic
    /// update, so a failure needs no rollback, a success is never claimed early, and a partial
    /// run produces a matching partial local state.
    @discardableResult
    func archiveSelection(_ selection: ArchiveSelectionSnapshot) -> Task<Void, Never> {
        perform(.archive, selection: selection)
    }

    /// Archives exactly one message, as a set of one.
    ///
    /// A convenience over ``archiveSelection(_:)`` rather than a second path to the boundary:
    /// one message is the ordinary case and does not deserve its own machinery, but it also must
    /// not get weaker validation than twelve messages do by going somewhere else.
    @discardableResult
    func archiveMessage(_ messageID: MailMessageID) -> Task<Void, Never> {
        guard case .loaded = state,
              let message = messagesInScope.first(where: { $0.id == messageID }),
              let selection = makeArchiveSelection(
                  forSenderKey: message.sender.groupingKey,
                  messageIDs: [messageID]
              )
        else {
            return failMutation(.archive, [messageID], .messageNotInLoadedWindow)
        }
        return archiveSelection(selection)
    }

    /// Puts the messages of the most recent undoable archive back, if the offer is still open.
    ///
    /// A real request to Gmail per message, through the same boundary the archive went through —
    /// not a local correction. It succeeds per message only when Gmail confirms, and its failures
    /// are reported separately from the archive's successes: the archive really did happen, and
    /// saying otherwise because the undo failed would be the app rewriting history it does not
    /// own.
    ///
    /// It restores **only** the messages that transaction archived. Nothing is inferred into the
    /// set — not the rest of the sender, not the rest of the thread, not messages archived by an
    /// earlier transaction.
    @discardableResult
    func undoLastArchive() -> Task<Void, Never> {
        guard let undoable = undoableArchive, undoable.isUndoable else { return .alreadyFinished }
        return perform(.restoreToInbox, transaction: undoable)
    }

    /// Dismisses the result banner.
    ///
    /// **Does not withdraw the undo offer.** That is the behaviour change this interval makes
    /// deliberately: closing a sheet is how somebody gets back to their mailbox, not how they
    /// say the archive was what they wanted. The offer lives in the transaction file and ends
    /// only for the reasons ``MailMutationTransaction`` names.
    func dismissMutationActivity() {
        guard mutationActivity?.isRunning != true else { return }
        mutationActivity = nil
    }

    /// The local record of what this app has changed, newest first.
    ///
    /// Read on demand rather than held, because it is a drawer the user opens, not state the
    /// dashboard renders.
    ///
    /// **Reads only. Nothing here contacts a provider.** Opening Activity, scrolling it, and
    /// opening a row are all answered from the local transaction file and the window already in
    /// memory; the only thing on that screen that can reach Gmail is the existing Undo.
    ///
    /// Scoped to the connected account, and empty when there is none — so a history is never
    /// shown beside a mailbox it does not belong to, and never shown at all while signed out.
    func mutationHistory() async -> [MailMutationTransaction] {
        guard let account else { return [] }
        return await mutationRecords.transactions(for: account)
    }

    /// The messages of a past transaction that are still described by the loaded window.
    ///
    /// Activity stores identifiers, not mail. When the window happens to still hold the messages
    /// a transaction named, this is what lets a row say which ones they were — resolved from the
    /// window in memory, which came from Gmail or from the local cache, and never re-fetched.
    ///
    /// Returning fewer than the transaction named is the ordinary case, not a failure. An
    /// archive from last month names messages no longer in a 250-message inbox window, and the
    /// right answer there is "3 messages archived" rather than three subjects kept on disk
    /// forever so that an old row stays decorative. Callers show what comes back and degrade
    /// gracefully when nothing does.
    ///
    /// Ordered to match the transaction's own list, so a detail view reads in the order the
    /// operation ran.
    func resolvedMessages(for transaction: MailMutationTransaction) -> [MailMessage] {
        guard let account, transaction.accountAddress == account.emailAddress.address else { return [] }

        let loaded = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return transaction.succeededMessageIDs.compactMap { loaded[$0] }
    }

    /// The Activity history for the connected account, newest first, ready to render.
    ///
    /// One call so a screen cannot assemble half of this and forget the rest: each entry is a
    /// transaction, whatever the loaded window can still say about its messages, and whether the
    /// *existing* undo offer happens to be this one.
    ///
    /// **Performs no provider call.** The transactions come off disk, the metadata comes out of
    /// the window already in memory, and the undoability comes from a value the session already
    /// holds.
    func activityHistory() async -> [ActivityEntry] {
        await mutationHistory().map { transaction in
            ActivityEntry(
                transaction: transaction,
                resolvedMessages: resolvedMessages(for: transaction),
                isUndoable: canUndo(transaction)
            )
        }
    }

    /// Whether `transaction` is the one the existing undo path would act on right now.
    ///
    /// Asked by the Activity screen before it offers Undo, so that being *visible* never makes an
    /// older or superseded transaction actionable. It adds no policy of its own — it compares
    /// against ``undoableArchive``, which is the same value the review screen and the
    /// confirmation sheet offer from, established by ``restoreUndoOffer(for:)``.
    func canUndo(_ transaction: MailMutationTransaction) -> Bool {
        guard let undoable = undoableArchive, undoable.isUndoable else { return false }
        guard let account, transaction.accountAddress == account.emailAddress.address else { return false }
        return undoable.id == transaction.id && !isMutating
    }

    // MARK: - The one path both mutations take

    /// Undo, expressed as a selection over the transaction's confirmed messages.
    private func perform(
        _ operation: MailMutationOperation,
        transaction: MailMutationTransaction
    ) -> Task<Void, Never> {
        // The undo names the messages *the transaction confirmed*, not anything read from the
        // current window — an archived message is by definition no longer in an Inbox-scoped
        // window, so re-deriving the set from the screen would restore nothing.
        guard let selection = MailArchiveSelection(
            messageIDs: transaction.succeededMessageIDs,
            accountAddress: transaction.accountAddress
        ) else { return .alreadyFinished }

        return execute(
            .restoreToInbox,
            selection: selection,
            messageIDs: transaction.succeededMessageIDs,
            undoing: transaction
        )
    }

    private func perform(
        _ operation: MailMutationOperation,
        selection snapshot: ArchiveSelectionSnapshot
    ) -> Task<Void, Never> {
        // The duplicate-submission guard, in two parts. The first refuses anything while a
        // mutation is out, so two clicks are one mutation even if both reach this method. The
        // second refuses a *frozen set that has already been executed* — which is the case the
        // first one misses, because by then nothing is running any more and the sheet is still
        // on screen showing the same confirmed set.
        guard !isMutating else { return .alreadyFinished }
        guard mutationActivity?.id != snapshot.id else { return .alreadyFinished }

        if let refusal = validateAgainstLoadedWindow(snapshot) {
            return failMutation(operation, snapshot.messageIDs, refusal)
        }
        guard let selection = snapshot.selection() else {
            return failMutation(operation, snapshot.messageIDs, .selectionChanged)
        }

        return execute(operation, selection: selection, messageIDs: snapshot.messageIDs, undoing: nil)
    }

    /// Runs a validated selection and applies whatever came back.
    private func execute(
        _ operation: MailMutationOperation,
        selection: MailArchiveSelection,
        messageIDs: [MailMessageID],
        undoing: MailMutationTransaction?
    ) -> Task<Void, Never> {
        guard !isMutating else { return .alreadyFinished }
        guard let archiver else { return failMutation(operation, messageIDs, .notSupported) }
        guard case .loaded(let snapshot) = state else {
            return failMutation(operation, messageIDs, .messageNotInLoadedWindow)
        }
        guard archiveCapability != .unsupported else {
            return failMutation(operation, messageIDs, .notSupported)
        }
        guard archiveCapability.isGranted else {
            return failMutation(operation, messageIDs, .permissionRequired)
        }
        guard selection.accountAddress == snapshot.account.emailAddress.address else {
            return failMutation(operation, messageIDs, .accountChanged)
        }

        let activityID = selection.operationID
        mutationActivity = MessageMutationActivity(
            id: activityID,
            operation: operation,
            messageIDs: selection.messageIDs,
            accountAddress: selection.accountAddress
        )

        return runMutation { [self] in
            // Asked of the provider rather than taken from the snapshot: the snapshot records
            // which account the window was *read* for, and the question here is which account
            // the token in the adapter authenticates *now*. Those differ exactly when it
            // matters — and for a set, they have to be the same for every message in it, which
            // is guaranteed by the set carrying one account address rather than one per message.
            guard await provider.currentConnection().account?.emailAddress.address == selection.accountAddress else {
                await finish(
                    .refused(selection, operation: operation, because: .accountChanged),
                    undoing: undoing
                )
                return
            }

            // Recorded here rather than when the confirmation opened, or when it was validated:
            // this is the first line past which a request really can go out. A run refused before
            // it — a swapped account, a withdrawn grant — left the mailbox alone and stays
            // re-confirmable.
            executedSelectionIDs.insert(selection.operationID)

            let receipt = await MessageSetMutator(archiver: archiver).perform(
                operation,
                selection,
                onMessageCompleted: { [weak self] completed in
                    await self?.advanceProgress(of: activityID, to: completed)
                }
            )
            await finish(receipt, undoing: undoing)
        }
    }

    /// Moves the progress counter, if the activity it belongs to is still the current one.
    private func advanceProgress(of activityID: UUID, to completed: Int) {
        guard let activity = mutationActivity, activity.id == activityID, activity.isRunning else { return }
        mutationActivity = activity.advancingProgress(to: completed)
    }

    /// Applies a finished run, exactly once, and writes it down.
    ///
    /// Written to be safe to call more than once for the same operation: the transaction store
    /// replaces by operation ID rather than appending, and the reconciliation below is idempotent
    /// — setting a label set that is already set changes nothing. A repeated completion therefore
    /// produces one transaction and one local state, not two.
    private func finish(
        _ receipt: MailArchiveSetReceipt,
        undoing: MailMutationTransaction?
    ) async {
        let occurredAt = now()

        // Only the messages Gmail confirmed. A failed message keeps whatever labels it had,
        // which is what "failures remain in your Inbox" means in code.
        reconcile(receipt)

        let recordOutcome = await writeTransaction(receipt, at: occurredAt, undoing: undoing)
        mutationActivity = mutationActivity?.settingPhase(
            .finished(receipt, localRecordWarning: recordOutcome.warning)
        )

        if receipt.confirmedCount > 0 {
            await republishAfterMutation()
        }
    }

    /// Writes the durable transaction and moves the undo offer to match it.
    ///
    /// The lifecycle policy, in one place: **one undoable archive transaction per account**.
    /// A new archive that confirmed anything supersedes the previous offer — the superseded
    /// transaction stays in the file as audit history, and the UI never claims two independent
    /// undos are available. An undo marks the transaction it reversed as undone and leaves no
    /// offer behind, because undoing an undo is archiving, and archiving is something the user
    /// asks for explicitly.
    @discardableResult
    private func writeTransaction(
        _ receipt: MailArchiveSetReceipt,
        at occurredAt: Date,
        undoing: MailMutationTransaction?
    ) async -> MutationRecordOutcome {
        let transaction = MailMutationTransaction.completing(receipt, at: occurredAt)

        // Superseding happens before the new transaction is written, so a crash between the two
        // leaves no file in which two transactions both claim to be undoable.
        if transaction.isUndoable, let previous = undoableArchive, previous.id != transaction.id {
            _ = await mutationRecords.record(previous.settingUndoState(.superseded))
        }

        let outcome = await mutationRecords.record(transaction)

        switch receipt.operation {
        case .archive:
            // An archive that confirmed nothing leaves the previous offer alone: it is still a
            // true statement about messages that are still archived.
            if transaction.isUndoable { undoableArchive = transaction }

        case .restoreToInbox:
            guard let undoing else { break }
            if receipt.confirmedCount == undoing.succeededCount {
                // Everything came back, so there is nothing left to undo — and nothing left for
                // the transaction to name. Narrowed to empty rather than marked `.undone` with
                // its list intact, so the full and partial paths agree about what the list
                // means: the messages this archive still has out of the inbox. Leaving two
                // identifiers on a fully-undone archive made it read as *partly* undone, because
                // "how many came back" is the difference between what it confirmed and what it
                // still names.
                _ = await mutationRecords.record(undoing.narrowingUndoOffer(to: []))
                undoableArchive = nil
            } else {
                // A partial undo leaves the messages that did *not* come back still archived,
                // so the offer stands — narrowed to exactly those, and never re-widened to
                // include the ones already restored.
                //
                // Narrowing the *offer* and not the *history*: the archive's confirmed count,
                // selected count, and timestamp are carried through untouched, so Activity keeps
                // saying what that archive did rather than what is left of it.
                let remaining = undoing.succeededMessageIDs.filter { !receipt.confirmedMessageIDs.contains($0) }
                let narrowed = undoing.narrowingUndoOffer(to: remaining)
                _ = await mutationRecords.record(narrowed)
                undoableArchive = narrowed.isUndoable ? narrowed : nil
            }
        }

        return outcome
    }

    /// Brings the in-memory window into line with what the provider reported, message by
    /// message.
    ///
    /// Labels are *replaced* with the ones on the receipt rather than edited towards what the
    /// app expected, so the window says what the mailbox says. Messages the provider refused are
    /// not touched at all, which is what makes a partial run produce a matching partial local
    /// state. Each message keeps its place in the window whether or not it is still in scope —
    /// membership is derived from labels by ``messagesInScope``, which is what makes an undo
    /// restore messages to their original positions instead of appending them to the end.
    private func reconcile(_ receipt: MailArchiveSetReceipt) {
        let confirmed = receipt.confirmedLabels
        guard !confirmed.isEmpty else { return }

        for (index, existing) in messages.enumerated() {
            guard let labels = confirmed[existing.id] else { continue }
            messages[index] = MailMessage(
                id: existing.id,
                threadID: existing.threadID,
                sender: existing.sender,
                subject: existing.subject,
                receivedAt: existing.receivedAt,
                labels: labels,
                hasListUnsubscribeHeader: existing.hasListUnsubscribeHeader
            )
        }
    }

    /// Recomputes and re-persists everything derived from the window.
    ///
    /// Summaries, proposals, protection, plan membership, the saved plan's staleness, and the
    /// cache file all come from one place — ``publishSnapshot(for:isLoadingMore:persist:)`` —
    /// so a mutation gets the same recomputation a newly-loaded page does, and no derived value
    /// can be left describing the mailbox as it was a moment ago.
    private func republishAfterMutation() async {
        guard case .loaded(let snapshot) = state else { return }
        await publishSnapshot(for: snapshot.account, isLoadingMore: false, persist: true)
    }

    /// Everything about a frozen set that can be checked without asking the provider.
    ///
    /// Returns the refusal, or `nil` when the set still describes the window on screen.
    private func validateAgainstLoadedWindow(_ selection: ArchiveSelectionSnapshot) -> MailMutationError? {
        guard case .loaded(let snapshot) = state else { return .messageNotInLoadedWindow }
        guard archiveCapability != .unsupported else { return .notSupported }
        guard archiveCapability.isGranted else { return .permissionRequired }
        guard !selection.messages.isEmpty else { return .selectionChanged }
        guard selection.accountAddress == snapshot.account.emailAddress.address else { return .accountChanged }

        // One confirmation is one operation. A frozen set that has already been through the
        // mutator is refused for the life of the session rather than re-sent, so a second press
        // on a sheet still showing a finished result cannot become a second archive.
        guard !executedSelectionIDs.contains(selection.id) else { return .alreadyExecuted }

        // The window has to be the same *kind* of window, not just one that happens to contain
        // the identifiers. Switching scope changes what the review screen was a review of.
        guard selection.scope == scope else { return .selectionChanged }

        // Every message must still be loaded, still in scope, still this sender's, and still in
        // the inbox. The sender check is what stops a set from crossing a sender boundary between
        // the review that built it and the confirmation that runs it; the inbox check is what
        // stops an archive from being sent for a message that has already left it — archived in
        // Gmail itself, or by an earlier confirmation — which would be a request whose answer the
        // user could not tell apart from the one they asked for.
        let live = Dictionary(uniqueKeysWithValues: messagesInScope.map { ($0.id, $0) })
        for message in selection.messages {
            guard let loaded = live[message.id] else { return .selectionChanged }
            guard loaded.sender.groupingKey == selection.senderKey else { return .selectionChanged }
            guard loaded.labels.contains(.inbox) else { return .selectionChanged }
        }
        return nil
    }

    /// Reports a refusal without contacting the provider at all.
    private func failMutation(
        _ operation: MailMutationOperation,
        _ messageIDs: [MailMessageID],
        _ error: MailMutationError
    ) -> Task<Void, Never> {
        mutationActivity = MessageMutationActivity(
            id: UUID(),
            operation: operation,
            messageIDs: messageIDs,
            accountAddress: account?.emailAddress.address ?? "",
            phase: .refused(error)
        )
        return .alreadyFinished
    }

    /// Runs a mutation on its own task, so cancelling a load cannot abandon it.
    private func runMutation(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let task = Task { @MainActor in
            await operation()
            mutationTask = nil
        }
        mutationTask = task
        return task
    }

    /// Cancels a set archive that is still working through its messages.
    ///
    /// Honest about what it can promise: the request currently with Gmail cannot be recalled, so
    /// this stops the run *before the next message* and reports the remainder as never attempted.
    /// A set of twelve cancelled after four is four archived messages and eight untouched ones,
    /// and the result says exactly that.
    func cancelMutation() {
        guard isMutating else { return }
        mutationTask?.cancel()
    }

    private func currentArchiveCapability() async -> MailMutationCapability {
        guard let archiver else { return .unsupported }
        return await archiver.archiveCapability()
    }

    /// Re-establishes the undo offer for `account` from the local transaction file.
    ///
    /// Called whenever a window is published, which is what makes the offer survive a relaunch:
    /// the app comes up, restores or loads a window, reads the most recent undoable transaction
    /// for the connected account, and offers it again. Four things have to hold, and all four
    /// are checked here rather than at the moment the button is pressed, so an offer is never
    /// shown that could not be honoured:
    ///
    /// - the transaction belongs to the account that is connected *now*;
    /// - it is an archive, and it confirmed at least one message;
    /// - it is still in the ``MailMutationTransaction/UndoState/undoable`` state;
    /// - the grant still covers archiving, since undo is a write like any other.
    ///
    /// An offer already in memory is left alone: it is the same value, and reassigning it on
    /// every published page would be extra churn for no change.
    private func restoreUndoOffer(for account: MailAccount) async {
        guard archiveCapability.isGranted else {
            undoableArchive = nil
            return
        }
        guard undoableArchive == nil else { return }
        undoableArchive = await mutationRecords.latestUndoableTransaction(for: account)
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
            return .empty(window: CleanupPlanWindow(loadedMessageCount: 0, hasMoreBeyondWindow: false, scope: scope))
        }

        var messagesBySender: [SenderSummary.ID: [MailMessage]] = [:]
        for message in messagesInScope {
            messagesBySender[message.sender.groupingKey, default: []].append(message)
        }

        return CleanupPlanner.plan(
            requests: requests,
            messagesBySender: messagesBySender,
            proposals: snapshot.proposals,
            window: snapshot.planWindow(),
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

        reset()
        storedPlan = await planStore.load(for: account)
        merge(cached.messages)
        nextPageToken = cached.nextPageToken
        loadedPageCount = cached.messages.isEmpty ? 0 : 1
        restoredFromCacheAt = cached.savedAt

        // Summaries are derived data stored beside their source. Trust them when they still
        // add up to the stored messages, and rebuild them when they do not, rather than
        // showing counts that disagree with the window they claim to describe.
        let window = messagesInScope
        let senders = cached.summariesMatchMessages && window.count == cached.messages.count
            ? SenderAggregator.sort(cached.senders, by: sortOrder)
            : await aggregate(window)

        // Proposals are never stored, only recomputed. That is what makes a rules change take
        // effect on the next launch instead of leaving last week's verdicts on screen.
        let proposals = await makeProposals(senders: senders, messages: window)
        archiveCapability = await currentArchiveCapability()

        state = .loaded(
            InboxSnapshot(
                account: account,
                loadedMessageCount: window.count,
                senders: senders,
                sortOrder: sortOrder,
                scope: scope,
                hasMoreMessages: nextPageToken != nil,
                isLoadingMore: false,
                loadedPageCount: loadedPageCount,
                proposals: proposals,
                cachedAt: cached.savedAt
            )
        )
        refreshSavedPlan()
        await restoreUndoOffer(for: account)
        return true
    }

    private func loadFirstPage(for account: MailAccount) async {
        reset()
        state = .loading(account)

        storedPlan = await planStore.load(for: account)

        do {
            let page = try await provider.fetchMessages(currentFirstPageRequest)
            try Task.checkCancellation()
            merge(page.messages)
            nextPageToken = page.nextPageToken
            loadedPageCount = 1
            await publishSnapshot(for: account, isLoadingMore: false, persist: true)
        } catch {
            let providerError = MailProviderError.wrapping(error)
            if providerError.requiresReauthentication { reset() }
            state = .failed(providerError, account: providerError.requiresReauthentication ? nil : account)
        }
    }

    /// The loaded messages that still belong to the scope they were read from.
    ///
    /// Everything the user sees, everything the rules reason over, and everything written to
    /// the cache is derived from *this*, not from ``messages``. The two differ only after an
    /// archive: the archived message stays in ``messages`` so an undo can restore it to its
    /// original position, and drops out of here immediately because an inbox-scoped refresh
    /// would no longer return it.
    ///
    /// Deriving membership rather than deleting the entry is what makes undo cheap and honest.
    /// A version that removed the message would have to remember where it had been, and would
    /// have nothing to put back if the undo arrived after a re-sort.
    private var messagesInScope: [MailMessage] {
        messages.filter(scope.retains)
    }

    /// Merges `incoming` into the window and reports how many messages were genuinely new.
    ///
    /// The merge itself belongs to ``MailMessageWindow``, which is the one place that decides
    /// what happens to a message seen twice: it keeps the position it was first listed at and
    /// the content it was last listed with. Routing every page through it — first page, extra
    /// page, and window restored from disk alike — is what keeps those three from disagreeing.
    ///
    /// The count is what tells a deep load whether a page was worth anything.
    @discardableResult
    private func merge(_ incoming: [MailMessage]) -> Int {
        let before = messages.count
        messages = MailMessageWindow.merging(messages, with: incoming)
        return messages.count - before
    }

    /// Aggregates off the main actor, publishes the result, and — when asked — stores it.
    ///
    /// Aggregation is linear in the loaded window, which stays small enough to be quick — but
    /// it grows with every page, so it is kept off the actor that draws the window.
    ///
    /// Proposals are recomputed here, from the *whole* window, every single time. That is what
    /// makes a deep load change its mind honestly: a sender who looked like a cleanup candidate
    /// over one page can become protected over five, and the dashboard must show the second
    /// verdict rather than the first one it happened to compute.
    ///
    /// `persist` is false for the intermediate pages of a deep load. Writing the cache after
    /// every page would mean ten file writes for one user action, and the final write covers
    /// everything the earlier ones would have.
    private func publishSnapshot(
        for account: MailAccount,
        isLoadingMore: Bool,
        persist: Bool
    ) async {
        let window = messagesInScope
        let senders = await aggregate(window)
        let proposals = await makeProposals(senders: senders, messages: window)
        archiveCapability = await currentArchiveCapability()

        // A cancelled load still publishes what it read — dropping it would throw away pages
        // the user waited for — but it never claims to still be loading.
        let stillLoading = isLoadingMore && !Task.isCancelled

        state = .loaded(
            InboxSnapshot(
                account: account,
                loadedMessageCount: window.count,
                senders: senders,
                sortOrder: sortOrder,
                scope: scope,
                hasMoreMessages: nextPageToken != nil,
                isLoadingMore: stillLoading,
                loadedPageCount: loadedPageCount,
                proposals: proposals,
                // Sticky: appending a page to a restored window does not make the pages
                // underneath it fresh, and only a full reload clears this.
                cachedAt: restoredFromCacheAt
            )
        )

        refreshSavedPlan()
        // After `archiveCapability`, because an offer is only shown when the grant still covers
        // undoing it. This is the call that makes the offer survive a relaunch: every published
        // window re-derives it from the local transaction file for the account on screen.
        await restoreUndoOffer(for: account)

        guard persist else { return }

        await cache.save(
            CachedInbox(
                account: account,
                messages: window,
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

    /// Re-checks the stored plan against the window currently on screen.
    private func refreshSavedPlan() {
        savedPlan = storedPlan?.restored(into: state.snapshot)
    }

    private func reset() {
        storedPlan = nil
        savedPlan = nil
        messages = []
        nextPageToken = nil
        loadedPageCount = 0
        restoredFromCacheAt = nil
        // Dropped rather than ended. The offer is durable, so the next published window
        // re-derives it from the transaction file for whichever account is connected then —
        // which is both how it survives a reload and how a sign-in as somebody else cannot
        // inherit the previous account's offer. The result banner has no such backing store and
        // simply goes.
        undoableArchive = nil
        mutationActivity = nil
        archiveCapability = .unsupported
    }
}

private extension Task where Success == Void, Failure == Never {
    /// A task that has nothing to do, returned when an operation is not applicable.
    ///
    /// Callers still get something to await, and — unlike routing the no-op through `run` —
    /// requesting an inapplicable operation does not cancel whatever is already running.
    static var alreadyFinished: Task<Void, Never> { Task {} }
}

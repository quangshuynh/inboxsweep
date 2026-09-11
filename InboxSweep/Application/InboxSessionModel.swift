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
    /// See ``UndoableArchive`` for exactly how long that is. It is not persisted and does not
    /// expire on a timer.
    private(set) var undoableArchive: UndoableArchive?

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

    // MARK: - Archiving one message
    //
    // The app's only write. Everything here is scoped to one message the user named and
    // confirmed: there is no batch form, no sender form, and nothing that a proposal, a saved
    // plan, or a dry run can reach. A recommendation can lead the user to the review screen and
    // stops there.

    /// Whether this session could archive at all, ignoring whether permission has been granted.
    ///
    /// Distinguishes "the sample mailbox cannot be changed" from "your grant does not cover it
    /// yet", so the UI offers a reconnect only where reconnecting would help.
    var canOfferArchiving: Bool { archiveCapability != .unsupported }

    /// Whether a mutation is in flight right now.
    var isMutating: Bool { mutationActivity?.isRunning == true }

    /// Whether this specific message can be offered an Archive action.
    ///
    /// Everything the confirmation depends on, checked before the button is shown rather than
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
    /// Separate from ``archiveMessage(_:)`` on purpose: granting a permission and changing a
    /// mailbox are two decisions, and rolling them into one action would mean the click that
    /// consented was also the click that archived.
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
            }
        }
    }

    /// Archives exactly one message, after the caller has confirmed it with the user.
    ///
    /// This method performs no confirming of its own — by the time it is called the user has
    /// seen the message and pressed the confirming button. What it does do is refuse: every
    /// precondition is re-checked here against the state as it is *now*, because the window can
    /// reload and the account can change between choosing a message and confirming it.
    ///
    /// Local state is reconciled only after Gmail says the change happened. There is no
    /// optimistic update, so a failure needs no rollback and a success is never claimed early.
    @discardableResult
    func archiveMessage(_ messageID: MailMessageID) -> Task<Void, Never> {
        perform(.archive, messageID: messageID)
    }

    /// Puts the last archived message back, if the offer is still open.
    ///
    /// A real request to Gmail through the same boundary the archive went through — not a local
    /// correction. It succeeds only when Gmail confirms, and its failure is reported separately
    /// from the archive's success: the archive really did happen, and saying otherwise because
    /// the undo failed would be the app rewriting history it does not own.
    @discardableResult
    func undoLastArchive() -> Task<Void, Never> {
        guard let undoable = undoableArchive else { return .alreadyFinished }
        return perform(.restoreToInbox, messageID: undoable.messageID)
    }

    /// Dismisses the result of the last mutation, and with it the undo offer.
    func dismissMutationActivity() {
        guard mutationActivity?.isRunning != true else { return }
        mutationActivity = nil
        undoableArchive = nil
    }

    /// The local record of what this app has changed, newest first.
    ///
    /// Read on demand rather than held, because it is a receipt drawer the user opens, not
    /// state the dashboard renders.
    func mutationHistory() async -> [MailMutationRecord] {
        guard let account else { return [] }
        return await mutationRecords.records(for: account)
    }

    /// The one path both mutations take.
    private func perform(
        _ operation: MailMutationOperation,
        messageID: MailMessageID
    ) -> Task<Void, Never> {
        // The duplicate-submission guard. A second press while the first is out returns a task
        // that does nothing, so two clicks are one mutation even if both reach this method.
        guard !isMutating else { return .alreadyFinished }
        guard let archiver else { return failMutation(operation, messageID, .notSupported) }
        guard case .loaded(let snapshot) = state else {
            return failMutation(operation, messageID, .messageNotInLoadedWindow)
        }
        guard archiveCapability != .unsupported else {
            return failMutation(operation, messageID, .notSupported)
        }
        guard archiveCapability.isGranted else {
            return failMutation(operation, messageID, .permissionRequired)
        }

        // For an archive the message must be in the window on screen. For an undo it must not —
        // it has just left the inbox — so what is checked is that this session is the one that
        // archived it, which the undo offer is the record of.
        switch operation {
        case .archive:
            guard messagesInScope.contains(where: { $0.id == messageID }) else {
                return failMutation(operation, messageID, .messageNotInLoadedWindow)
            }
        case .restoreToInbox:
            guard let undoable = undoableArchive, undoable.messageID == messageID else {
                return failMutation(operation, messageID, .messageNotInLoadedWindow)
            }
            guard undoable.accountAddress == snapshot.account.emailAddress.address else {
                return failMutation(operation, messageID, .accountChanged)
            }
        }

        let accountAddress = snapshot.account.emailAddress.address
        let request = MailArchiveRequest(messageID: messageID, accountAddress: accountAddress)

        mutationActivity = MessageMutationActivity(
            id: request.operationID,
            operation: operation,
            messageID: messageID,
            accountAddress: accountAddress
        )

        return runMutation { [self] in
            // Asked of the provider rather than taken from the snapshot: the snapshot records
            // which account the window was *read* for, and the question here is which account
            // the token in the adapter authenticates *now*. Those differ exactly when it
            // matters.
            guard await provider.currentConnection().account?.emailAddress.address == accountAddress else {
                await finish(request, operation, with: .failure(.accountChanged))
                return
            }

            do {
                let receipt = operation == .archive
                    ? try await archiver.archive(request)
                    : try await archiver.restoreToInbox(request)
                await finish(request, operation, with: .success(receipt))
            } catch {
                await finish(request, operation, with: .failure(.wrapping(error)))
            }
        }
    }

    /// Applies a confirmed result, or reports a failure, exactly once.
    ///
    /// Written to be safe to call more than once for the same request: the record store replaces
    /// by operation ID rather than appending, and the reconciliation below is idempotent —
    /// setting a label set that is already set changes nothing. A repeated completion therefore
    /// produces one record and one local state, not two.
    private func finish(
        _ request: MailArchiveRequest,
        _ operation: MailMutationOperation,
        with result: Result<MailArchiveReceipt, MailMutationError>
    ) async {
        let occurredAt = now()

        switch result {
        case .failure(let error):
            await writeRecord(request, operation, outcome: .failed, at: occurredAt)
            mutationActivity = mutationActivity?.settingPhase(.failed(error))
            // An undo that failed leaves the message archived, and the offer to undo it again
            // stands — unless the reason means there is nothing left to undo.
            if operation == .archive || error.requiresReview {
                undoableArchive = nil
            }

        case .success(let receipt):
            reconcile(receipt)

            let recordOutcome = await writeRecord(request, operation, outcome: .confirmed, at: occurredAt)
            mutationActivity = mutationActivity?.settingPhase(
                .succeeded(localRecordWarning: recordOutcome.warning)
            )

            switch operation {
            case .archive:
                undoableArchive = UndoableArchive(
                    messageID: receipt.messageID,
                    accountAddress: request.accountAddress,
                    archivedAt: occurredAt
                )
            case .restoreToInbox:
                undoableArchive = nil
            }

            await republishAfterMutation()
        }
    }

    @discardableResult
    private func writeRecord(
        _ request: MailArchiveRequest,
        _ operation: MailMutationOperation,
        outcome: MailMutationRecord.Outcome,
        at occurredAt: Date
    ) async -> MutationRecordOutcome {
        await mutationRecords.record(
            MailMutationRecord(
                id: request.operationID,
                operation: operation,
                messageID: request.messageID,
                accountAddress: request.accountAddress,
                occurredAt: occurredAt,
                outcome: outcome
            )
        )
    }

    /// Brings the in-memory window into line with what the provider reported.
    ///
    /// Labels are *replaced* with the ones on the receipt rather than edited towards what the
    /// app expected, so the window says what the mailbox says. The message keeps its place in
    /// the window whether or not it is still in scope — membership is derived from its labels
    /// by ``messagesInScope``, which is what makes an undo restore its original position
    /// instead of appending it to the end.
    private func reconcile(_ receipt: MailArchiveReceipt) {
        guard let index = messages.firstIndex(where: { $0.id == receipt.messageID }) else { return }
        let existing = messages[index]
        messages[index] = MailMessage(
            id: existing.id,
            threadID: existing.threadID,
            sender: existing.sender,
            subject: existing.subject,
            receivedAt: existing.receivedAt,
            labels: receipt.labelsAfterMutation,
            hasListUnsubscribeHeader: existing.hasListUnsubscribeHeader
        )
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

    /// Reports a refusal without contacting the provider at all.
    private func failMutation(
        _ operation: MailMutationOperation,
        _ messageID: MailMessageID,
        _ error: MailMutationError
    ) -> Task<Void, Never> {
        mutationActivity = MessageMutationActivity(
            id: UUID(),
            operation: operation,
            messageID: messageID,
            accountAddress: account?.emailAddress.address ?? "",
            phase: .failed(error)
        )
        if error.requiresReview { undoableArchive = nil }
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

    private func currentArchiveCapability() async -> MailMutationCapability {
        guard let archiver else { return .unsupported }
        return await archiver.archiveCapability()
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
        // A reload, a scope change, a sign-out, and a re-connect all throw the window away, and
        // an undo offer that outlived the window it referred to would be pointing at a message
        // the app can no longer show the user. The result banner goes with it. See
        // ``UndoableArchive`` for the full list of things that end the offer.
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

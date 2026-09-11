import Foundation

/// One sender a user chose to preview, and what they chose to preview for it.
nonisolated struct SavedCleanupSelection: Hashable, Sendable, Identifiable {

    /// The sender's grouping key, as used everywhere else in the app.
    let senderKey: SenderSummary.ID

    /// The conceptual action chosen. Its associated value carries the keep-newest count or the
    /// age cutoff, so those need no separate storage.
    let action: PlannedCleanupAction

    var id: SenderSummary.ID { senderKey }

    init(senderKey: SenderSummary.ID, action: PlannedCleanupAction) {
        self.senderKey = senderKey
        self.action = action
    }
}

/// The choices a user made in the preview, kept so that closing the sheet does not discard
/// twenty minutes of deciding.
///
/// **What is stored is the choosing, not the conclusions.** Sender keys and chosen actions —
/// no proposals, no reasons, no protection verdicts, no counts of what would be affected. All
/// of that is derived from the loaded window and is recomputed on every launch, so a saved plan
/// cannot carry a stale verdict back onto the screen.
///
/// **A saved plan is not a scheduled one.** There is nothing in the app that could carry one
/// out, and restoring one re-opens a preview — it does not act, and there is no code path from
/// here to a provider. ``SafetyBoundaryTests`` asserts both.
nonisolated struct SavedCleanupPlan: Hashable, Sendable {

    /// The account these choices were made for.
    ///
    /// Checked on load: a plan is never applied to a different mailbox, because a sender key
    /// that means "the shop I buy from" in one account can mean nothing at all in another.
    let accountAddress: String

    /// The scope that was loaded when the choices were made.
    let scope: MailboxScope

    /// The chosen senders, in the order they were shown.
    let selections: [SavedCleanupSelection]

    /// Which ruleset was on screen when the user chose.
    ///
    /// The proposals that informed these choices came from this version. When the rules change,
    /// the advice the user was reading has changed too, and the plan is marked stale rather
    /// than quietly restored beside different reasoning.
    let rulesVersion: Int

    /// How many messages were loaded when the choices were made.
    ///
    /// A plan decided over 250 messages is not the same plan over 2,500 — the same action
    /// reaches a different set of mail — so the window size is part of what makes a plan stale.
    let loadedMessageCount: Int

    let savedAt: Date

    init(
        accountAddress: String,
        scope: MailboxScope,
        selections: [SavedCleanupSelection],
        rulesVersion: Int = CleanupProposalRules.version,
        loadedMessageCount: Int,
        savedAt: Date
    ) {
        self.accountAddress = accountAddress
        self.scope = scope
        self.selections = selections
        self.rulesVersion = rulesVersion
        self.loadedMessageCount = loadedMessageCount
        self.savedAt = savedAt
    }

    var isEmpty: Bool { selections.isEmpty }
    var senderKeys: [SenderSummary.ID] { selections.map(\.senderKey) }

    func action(forSenderKey key: SenderSummary.ID) -> PlannedCleanupAction? {
        selections.first { $0.senderKey == key }?.action
    }

    /// Whether this plan belongs to `account`.
    func belongs(to account: MailAccount) -> Bool {
        accountAddress.caseInsensitiveCompare(account.emailAddress.address) == .orderedSame
    }
}

/// A reason a saved plan no longer describes what the user decided.
///
/// Stated rather than silently corrected. A plan restored onto a window that has doubled in
/// size, or beside a ruleset that has changed its mind, is *usable* — but the user should be the
/// one to decide that, and they cannot if nothing tells them anything moved.
nonisolated enum CleanupPlanStaleness: Hashable, Sendable, Identifiable {

    /// The proposal rules changed since the choices were made.
    case rulesVersionChanged(saved: Int, current: Int)

    /// The plan was made over a different part of the mailbox.
    case scopeChanged(saved: MailboxScope, current: MailboxScope)

    /// Some chosen senders are not in the loaded window any more.
    case sendersNoLongerLoaded(count: Int)

    /// The loaded window has changed size enough that the same action reaches different mail.
    case windowChanged(saved: Int, current: Int)

    var id: String {
        switch self {
        case .rulesVersionChanged: "rules"
        case .scopeChanged: "scope"
        case .sendersNoLongerLoaded: "senders"
        case .windowChanged: "window"
        }
    }

    /// Whether this is serious enough that the choices should be re-made rather than resumed.
    ///
    /// A changed ruleset is: the proposals the user was reading are not the proposals they
    /// would see now. The rest are worth saying and not worth blocking on.
    var invalidatesPlan: Bool {
        if case .rulesVersionChanged = self { return true }
        return false
    }

    var explanation: String {
        switch self {
        case .rulesVersionChanged(let saved, let current):
            return """
                These choices were made against version \(saved) of InboxSweep's proposal rules, \
                and this build uses version \(current). The reasoning you were reading has \
                changed, so it is worth looking again rather than resuming.
                """
        case .scopeChanged(let saved, let current):
            return "These choices were made while reading \(saved.displayName); you are now reading \(current.displayName)."
        case .sendersNoLongerLoaded(let count):
            return "^[\(count) chosen sender](inflect: true) are not in the loaded window any more, so they have been left out."
        case .windowChanged(let saved, let current):
            return """
                These choices were made over \(saved.formatted()) loaded messages and there are \
                now \(current.formatted()). The same action reaches a different set of mail, so \
                the numbers will not match what you saw.
                """
        }
    }
}

/// A saved plan checked against the window that is actually loaded now.
///
/// Produced by ``SavedCleanupPlan/restored(into:)``, which drops selections whose senders are
/// gone rather than leaving the caller to handle a key that resolves to nothing.
nonisolated struct RestoredCleanupPlan: Hashable, Sendable {

    /// The plan as it was saved.
    let saved: SavedCleanupPlan

    /// The selections whose senders are still in the loaded window, in the saved order.
    let usableSelections: [SavedCleanupSelection]

    /// Everything that has moved since the plan was saved, in a fixed order.
    let staleness: [CleanupPlanStaleness]

    var isEmpty: Bool { usableSelections.isEmpty }

    /// Whether the plan should be re-made rather than resumed.
    var isInvalidated: Bool { staleness.contains(where: \.invalidatesPlan) }

    /// Whether anything at all has moved.
    var isStale: Bool { !staleness.isEmpty }
}

nonisolated extension SavedCleanupPlan {

    /// How much the loaded window can grow or shrink before the plan is called stale.
    ///
    /// A fifth. Small enough that a page or two of new mail over a 250-message window is not
    /// flagged as a change the user must think about; large enough that a deep load, which is
    /// the whole point of this interval's paging work, always is.
    static let windowChangeTolerance = 0.2

    /// Checks this plan against the window on screen.
    ///
    /// - Parameter snapshot: The currently loaded window, or `nil` when nothing is loaded.
    func restored(into snapshot: InboxSnapshot?) -> RestoredCleanupPlan {
        guard let snapshot else {
            return RestoredCleanupPlan(saved: self, usableSelections: [], staleness: [])
        }

        var staleness: [CleanupPlanStaleness] = []

        if rulesVersion != CleanupProposalRules.version {
            staleness.append(.rulesVersionChanged(saved: rulesVersion, current: CleanupProposalRules.version))
        }

        if scope != snapshot.scope {
            staleness.append(.scopeChanged(saved: scope, current: snapshot.scope))
        }

        let loadedKeys = Set(snapshot.senders.map(\.id))
        let usable = selections.filter { loadedKeys.contains($0.senderKey) }
        if usable.count < selections.count {
            staleness.append(.sendersNoLongerLoaded(count: selections.count - usable.count))
        }

        let change = abs(Double(snapshot.loadedMessageCount - loadedMessageCount))
        if loadedMessageCount > 0, change / Double(loadedMessageCount) > Self.windowChangeTolerance {
            staleness.append(.windowChanged(saved: loadedMessageCount, current: snapshot.loadedMessageCount))
        }

        return RestoredCleanupPlan(saved: self, usableSelections: usable, staleness: staleness)
    }
}

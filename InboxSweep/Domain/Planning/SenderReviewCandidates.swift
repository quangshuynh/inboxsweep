import Foundation

/// The messages a sender-level *Review messages to archive…* starts a review with.
///
/// ### What this is, and what it very deliberately is not
///
/// It is a **starting selection**. Somebody looking at one sender's dry-run preview can ask to
/// review the messages it names rather than ticking them one at a time, and this is the list the
/// review screen opens with the boxes already ticked. That is the whole of the convenience.
///
/// It is not an authorization, an intent, or a plan. Nothing here is sent anywhere, nothing here
/// is stored, and deriving it changes nothing — it is a filter over messages already in memory.
/// Between this value and a mailbox changing there are still four things a person has to do:
/// read the list, edit it, open a confirmation showing the exact set, and press the confirming
/// button. Every one of those remains exactly as it was before this type existed.
///
/// ### Why it is derived from the preview rather than computed afresh
///
/// There is no second engine here, and adding one would be the mistake. ``CleanupPlanner``
/// already decides what an action would reach, ``SenderProtection`` already decides what is held
/// back, and both verdicts arrive on ``ReviewedMessage``. This filters that list and counts what
/// it dropped. So the preselection cannot disagree with the preview the user was reading when
/// they pressed the button — it *is* the preview, with the protected messages removed.
///
/// ### The two rules
///
/// - **One sender.** Every identifier comes from one sender's reviewed messages, and the key is
///   carried so the session can check that again when the set is frozen.
/// - **Never a protected message.** The planner already holds those back; this filters on
///   protection a second time, so the guarantee does not depend on the planner continuing to
///   order its two filters the way it does today. A user who wants a protected message archived
///   can still tick it themselves, and the confirmation says so in as many words.
nonisolated struct SenderReviewCandidates: Equatable, Sendable {

    /// The sender every candidate belongs to.
    let senderKey: SenderSummary.ID

    /// The action whose preview produced the candidates.
    let action: PlannedCleanupAction

    /// The candidates, in the order the review screen lists them.
    ///
    /// Deterministic: it is the reviewed list's own order, which ends every comparison in the
    /// message identifier, filtered in place.
    let messageIDs: [MailMessageID]

    /// How many of this sender's messages are loaded at all.
    let loadedMessageCount: Int

    /// How many the preview would reach but protection holds back.
    let protectedMessageCount: Int

    /// How many the action's own scope never reached — too new for a cutoff, among the newest
    /// an action keeps, or any action over a sender with nothing old enough.
    let outOfScopeMessageCount: Int

    // MARK: - Deriving

    /// Derives the candidates from one sender's reviewed messages.
    ///
    /// - Parameters:
    ///   - reviewed: The sender's loaded messages, already classified under `action`. Anything
    ///     belonging to another sender is dropped rather than trusted, so a caller that passed
    ///     the wrong list produces an empty candidate set instead of a cross-sender one.
    ///   - senderKey: The sender the review is for.
    ///   - action: The action the preview was showing.
    static func derive(
        from reviewed: [ReviewedMessage],
        senderKey: SenderSummary.ID,
        under action: PlannedCleanupAction
    ) -> SenderReviewCandidates {
        let ownMessages = reviewed.filter { $0.message.sender.groupingKey == senderKey }
        let affected = ownMessages.filter(\.isAffectedByPlan)

        return SenderReviewCandidates(
            senderKey: senderKey,
            action: action,
            messageIDs: affected.filter { !$0.isProtected }.map(\.id),
            loadedMessageCount: ownMessages.count,
            protectedMessageCount: affected.count(where: \.isProtected),
            outOfScopeMessageCount: ownMessages.count - affected.count
        )
    }

    // MARK: - Derived

    var count: Int { messageIDs.count }

    var isEmpty: Bool { messageIDs.isEmpty }

    /// Why nothing was preselected, or `nil` when something was.
    ///
    /// Every empty case has a stated reason. A sender-level action that opened a review with no
    /// ticks and no explanation would read as a bug, and the one thing it must never read as is
    /// an invitation to tick everything instead.
    var emptyReason: EmptyReason? {
        guard isEmpty else { return nil }
        if loadedMessageCount == 0 { return .noLoadedMessages }
        if !action.movesMessages { return .actionMovesNoMessages }
        if outOfScopeMessageCount == loadedMessageCount { return .everyMessageOutOfScope }
        if protectedMessageCount == loadedMessageCount { return .everyMessageProtected }
        return .nothingLeftAfterProtection
    }

    /// Why a sender-level review opened with nothing ticked.
    nonisolated enum EmptyReason: Hashable, Sendable {

        /// The window holds no messages from this sender at all — it moved on, or the sender's
        /// mail was archived since the proposal was generated.
        case noLoadedMessages

        /// The chosen action moves no messages by definition.
        case actionMovesNoMessages

        /// The action's scope reached none of them: everything is newer than the cutoff, or
        /// among the newest the action keeps.
        case everyMessageOutOfScope

        /// Every loaded message is one InboxSweep holds back for its own sake.
        case everyMessageProtected

        /// The action reached some, and protection held back every one it reached.
        case nothingLeftAfterProtection
    }

    /// What to say when there is nothing ticked: the reason, and the way forward.
    ///
    /// Factual, and never an apology. "Nothing is selected" is a perfectly good answer for a
    /// sender whose mail is all recent or all starred, and the sentence says which of those it
    /// is rather than implying something went wrong. None of these offers a way to select
    /// something anyway — the review screen's own controls are still there, and a fallback the
    /// app invented to have something to tick would be the app choosing.
    var emptyExplanation: String? {
        let loaded = ProposalPhrasing.loadedMessages(loadedMessageCount)

        switch emptyReason {
        case .none:
            return nil
        case .noLoadedMessages:
            return """
                Nothing is selected: InboxSweep has no loaded messages from this sender any more. \
                The window may have been reloaded, or this sender's mail may have left it since the \
                suggestion was made. Loading more of the mailbox may find some.
                """
        case .actionMovesNoMessages:
            return """
                Nothing is selected, because "\(action.displayName)" doesn't move any message. \
                Choose an action above to see what one would reach, or tick messages yourself.
                """
        case .everyMessageOutOfScope:
            return """
                Nothing is selected: "\(action.displayName)" reaches none of the \(loaded) from \
                this sender. Choose a different action above, or tick messages yourself.
                """
        case .everyMessageProtected:
            return """
                Nothing is selected: every one of the \(loaded) from this sender is one InboxSweep \
                holds back — starred, marked Important, or part of a conversation. You can still \
                tick them yourself, and the confirmation will say so.
                """
        case .nothingLeftAfterProtection:
            return """
                Nothing is selected: of this sender's \(loaded), the \
                \(ProposalPhrasing.messages(protectedMessageCount)) "\(action.displayName)" would \
                have reached \(ProposalPhrasing.isAre(protectedMessageCount)) held back as \
                protected, and the rest are outside its scope. You can still tick them yourself.
                """
        }
    }

    /// What to say when something *was* ticked.
    ///
    /// Leads with the count, because "how many did it pick for me?" is the first question, and
    /// ends by saying nothing has happened yet, because that is the one somebody has to be sure
    /// of.
    var preselectionSummary: String {
        let heldBack = protectedMessageCount > 0
            ? " The \(ProposalPhrasing.messages(protectedMessageCount)) it would also have reached "
                + "\(ProposalPhrasing.isAre(protectedMessageCount)) protected, and \(protectedMessageCount == 1 ? "was" : "were") left unticked."
            : ""
        return """
            \(ProposalPhrasing.messages(count)) of \(ProposalPhrasing.loadedMessages(loadedMessageCount)) \
            selected from this preview.\(heldBack) Nothing has been archived — check the list, \
            change it however you like, and confirm.
            """
    }
}

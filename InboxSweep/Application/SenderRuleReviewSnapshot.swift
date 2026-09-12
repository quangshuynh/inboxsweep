import Foundation

/// Exactly what a rule would be, captured once, shown, and checked again before it is saved.
///
/// The same pattern as ``UnsubscribeReviewSnapshot`` and ``ArchiveSelectionSnapshot``, applied to
/// the one decision in this app whose consequences outlive the screen that made it. An archive
/// confirmation that drifted would archive the wrong messages once. **A rule that drifted would
/// archive the wrong sender's mail every time InboxSweep is opened**, indefinitely, without
/// asking again. So it is frozen hardest of the three.
///
/// ### derive, show, freeze, revalidate, authorize
///
/// - **derive**: ``InboxSessionModel/makeSenderRuleReview(forSenderKey:)`` reads the window in
///   memory and returns a value. Nothing is written, nothing is scheduled, and abandoning the
///   sheet costs one allocation.
/// - **show**: ``SenderRuleReviewSheet`` prints the exact address, the exact action, when it can
///   run, what it will not touch, and how to delete it.
/// - **freeze**: this type. The account, the sender key, the action, and the review context are
///   fixed here and never recomputed.
/// - **revalidate**: ``InboxSessionModel/validateAgainstLoadedWindow(_:)`` re-checks every one of
///   them against the state as it is at the moment the user presses the button, and refuses
///   rather than adjusting.
/// - **authorize**: only then, and only from an explicit press, is a ``SenderRule`` written.
///
/// ### A proposal is not a rule, and cannot become one
///
/// InboxSweep may say a rule could be useful. The affordance that says so opens *this*, and this
/// performs nothing. There is no code path from ``SenderCleanupProposal``, from a saved plan, from
/// a dry-run preview, or from an unsubscribe review to a stored rule that does not pass through a
/// person pressing the button on the review sheet. `RuleSafetyTests` asserts each of those.
nonisolated struct SenderRuleReviewSnapshot: Identifiable, Equatable, Sendable {

    /// The rule this review would create, identity and all.
    ///
    /// Carried whole rather than assembled at the end, so what is revalidated and what is saved
    /// are the same value rather than two constructions of it that could differ.
    let rule: SenderRule

    /// The account the review was opened under. Always ``SenderRule/accountAddress``, and checked
    /// separately so a mismatch is a refusal rather than an assumption.
    var accountAddress: String { rule.accountAddress }

    var id: UUID { rule.id }

    /// Which part of the mailbox was loaded when the review was frozen.
    ///
    /// Part of the review context rather than of the rule. A rule matches Inbox mail whatever
    /// scope was on screen, but a review that described "23 loaded messages from this sender"
    /// described *that* window, and a user deciding on those numbers deserves a refusal rather
    /// than a silent re-interpretation if the window changed underneath them.
    let scope: MailboxScope

    /// How many messages from this sender were loaded when the review was shown.
    ///
    /// Shown so the sentence about existing mail can be concrete. Not stored on the rule, and
    /// never used for matching.
    let loadedMessageCount: Int

    /// How many of those the rule would refuse to touch, as protection stands right now.
    ///
    /// An illustration of the policy on mail the user can actually see, rather than a promise
    /// about mail that has not arrived. Protection is re-evaluated per message at execution time.
    let protectedMessageCount: Int

    /// Whether this session could execute the rule at all.
    ///
    /// A rule may be created on a session that cannot archive: it is a durable authorization, and
    /// refusing to record one because today's grant is read-only would be refusing to remember a
    /// decision. The review says so plainly instead, and the rules list keeps saying it.
    let canExecute: Bool

    /// When it was frozen.
    let frozenAt: Date

    init(
        rule: SenderRule,
        scope: MailboxScope,
        loadedMessageCount: Int,
        protectedMessageCount: Int,
        canExecute: Bool,
        frozenAt: Date
    ) {
        self.rule = rule
        self.scope = scope
        self.loadedMessageCount = loadedMessageCount
        self.protectedMessageCount = protectedMessageCount
        self.canExecute = canExecute
        self.frozenAt = frozenAt
    }

    // MARK: - What the review must say

    var senderKey: String { rule.senderKey }
    var senderDisplayValue: String { rule.senderDisplayValue }
    var action: SenderRule.Action { rule.action }

    /// The sentence that keeps a rule from reading as a cleanup of what is already there.
    ///
    /// The most likely misreading of this screen, said before anything else: somebody who has
    /// just reviewed a sender's forty messages and is offered "archive mail from this sender"
    /// could reasonably think they are about to deal with the forty. They are not, and no press
    /// on this screen touches any of them.
    static let existingMailNote = """
        Nothing in your mailbox changes now. This is about mail that has not arrived yet: \
        messages already in your Inbox from this sender stay exactly where they are, and \
        archiving them is a separate thing you do from the message review.
        """

    /// How the authorization ends, said on the screen that grants it.
    static let revocationNote = """
        You can turn a rule off or delete it at any time from Rules, and disconnecting the \
        account deletes every rule with it. A rule only exists on this Mac.
        """

    /// What the rule does to protected mail, in the words the rules list also uses.
    static let protectionNote = """
        A rule never archives a message that looks worth keeping: anything starred, marked \
        Important by Gmail, or whose subject reads like security, money, health, employment, \
        government, travel, or a receipt. Those are left in your Inbox and InboxSweep tells you \
        it left them, so you can decide yourself.
        """
}

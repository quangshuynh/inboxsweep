import Foundation

/// What one pass of the local rules did, for the screen to report and for nothing else to act on.
///
/// Session-lifetime and never persisted. The *changes* a pass makes are written down as ordinary
/// ``MailMutationTransaction`` records with a ``MailMutationOrigin/rule(_:)`` origin, which is the
/// audit history; this is the transient "here is what just happened while you were looking at
/// something else" reading, and it is gone when the app quits.
///
/// ### Why the refusals are in here at all
///
/// Because the alternative is a lie of omission. A rule that archives four of a sender's six new
/// messages and silently leaves two has done something the user cannot see: their Inbox still
/// contains mail from a sender they believe is handled, and they have no way to learn that
/// InboxSweep looked at it and declined. The two it left are, by construction, the two most
/// likely to matter: protection only holds back starred, Important, and subjects that read as
/// security, money, health, employment, government, travel, or receipts.
///
/// So a pass reports what it declined as prominently as what it did, and
/// ``protectedSummary`` is the sentence the dashboard shows.
nonisolated struct SenderRuleRun: Identifiable, Equatable, Sendable {

    let id: UUID

    /// The account the pass ran for. Checked before the result is shown, so a run's summary can
    /// never appear beside a different mailbox.
    let accountAddress: String

    /// What each rule did, in the order the rules ran.
    let outcomes: [RuleOutcome]

    /// When the pass finished.
    let finishedAt: Date

    /// Why the pass stopped early, if it did.
    ///
    /// Only ever a session-wide failure: a withdrawn grant, a swapped account, a cancelled load.
    /// A single message that Gmail refused does not stop a pass and does not appear here.
    let haltedBy: MailMutationError?

    init(
        id: UUID = UUID(),
        accountAddress: String,
        outcomes: [RuleOutcome],
        finishedAt: Date,
        haltedBy: MailMutationError? = nil
    ) {
        self.id = id
        self.accountAddress = accountAddress
        self.outcomes = outcomes
        self.finishedAt = finishedAt
        self.haltedBy = haltedBy
    }

    /// What one rule did in one pass.
    nonisolated struct RuleOutcome: Identifiable, Equatable, Sendable {

        /// The rule that ran.
        let ruleID: SenderRule.ID

        /// The sender, as the rule names it, for a sentence the user can read.
        let senderDisplayValue: String

        /// How many messages Gmail confirmed archived.
        let archivedCount: Int

        /// How many were sent and refused. Counted, not named: there is nothing to offer about a
        /// message that did not change.
        let failedCount: Int

        /// The protected messages the rule declined to touch.
        let protectedCount: Int

        /// How many matching messages the pass limit left for next time.
        let deferredCount: Int

        var id: SenderRule.ID { ruleID }

        /// Whether anything at all happened worth mentioning.
        var isSilent: Bool {
            archivedCount == 0 && failedCount == 0 && protectedCount == 0 && deferredCount == 0
        }
    }

    // MARK: - Derived

    var archivedCount: Int { outcomes.reduce(0) { $0 + $1.archivedCount } }
    var protectedCount: Int { outcomes.reduce(0) { $0 + $1.protectedCount } }
    var failedCount: Int { outcomes.reduce(0) { $0 + $1.failedCount } }
    var deferredCount: Int { outcomes.reduce(0) { $0 + $1.deferredCount } }

    /// Whether this pass is worth putting in front of somebody.
    var isWorthShowing: Bool { !outcomes.allSatisfy(\.isSilent) || haltedBy != nil }

    /// What the pass did, in the words Activity uses for the same thing.
    ///
    /// Says what InboxSweep changed and stops there. It does not say the Inbox is now clear, or
    /// that the sender is handled, because a pass knows what it archived and nothing about what
    /// else is in somebody's mailbox.
    var archivedSummary: String? {
        guard archivedCount > 0 else { return nil }
        let rules = outcomes.filter { $0.archivedCount > 0 }
        if rules.count == 1, let only = rules.first {
            return archivedCount == 1
                ? "Archived 1 message from \(only.senderDisplayValue) by rule"
                : "Archived \(archivedCount) messages from \(only.senderDisplayValue) by rule"
        }
        return archivedCount == 1
            ? "Archived 1 message by rule"
            : "Archived \(archivedCount) messages by \(rules.count) rules"
    }

    /// What the pass refused to touch, and why that is the user's to decide.
    var protectedSummary: String? {
        guard protectedCount > 0 else { return nil }
        return protectedCount == 1
            ? "1 message was left in your Inbox because it looks worth keeping. Rules never archive those for you."
            : "\(protectedCount) messages were left in your Inbox because they look worth keeping. Rules never archive those for you."
    }

    /// What the pass could not finish, when the limit rather than an error stopped it.
    var deferredSummary: String? {
        guard deferredCount > 0 else { return nil }
        return deferredCount == 1
            ? "1 more matching message is waiting; InboxSweep will get to it the next time you reload."
            : "\(deferredCount) more matching messages are waiting; InboxSweep will get to them the next time you reload."
    }

    /// What went wrong for the whole pass, when something did.
    var failureSummary: String? {
        if let haltedBy {
            return "InboxSweep stopped applying your rules: \(haltedBy.errorDescription ?? "something went wrong"). Your rules are unchanged."
        }
        guard failedCount > 0 else { return nil }
        return failedCount == 1
            ? "Gmail refused 1 message, which is still in your Inbox. InboxSweep will try it again the next time you reload."
            : "Gmail refused \(failedCount) messages, which are still in your Inbox. InboxSweep will try them again the next time you reload."
    }

    /// The reminder that a rule-driven archive has no undo, said wherever a pass is reported.
    ///
    /// Not an apology and not fine print: it is the one way this differs from an archive the user
    /// confirmed, and somebody who has just been told InboxSweep changed their mailbox needs to
    /// know what they can do about it. See ``MailMutationTransaction/completing(_:at:origin:)``.
    static let noUndoNote = """
        There is no Undo for mail a rule archived. Archived mail is still in your Gmail account \
        under All Mail, and Gmail's own Move to Inbox puts a message back.
        """
}

import Foundation

/// One row of the Activity screen: a past mutation, in the words a person would use for it.
///
/// A view over ``MailMutationTransaction`` rather than a second stored model. Nothing here is
/// persisted, nothing here is a new fact, and every sentence is derived from counts the
/// transaction already holds — which is what stops the screen and the file from drifting apart.
///
/// ### What it is allowed to say
///
/// Only what InboxSweep attempted and what a provider confirmed. There is no phrasing in here
/// for "your inbox is cleaner", no total, no streak, and no claim about the state of a mailbox
/// today: an archive InboxSweep performed in March is not a promise about where that message is
/// now, because the user may well have moved it since.
///
/// Archive is not deletion, and the wording never implies it is.
nonisolated struct ActivityEntry: Identifiable, Hashable, Sendable {

    let transaction: MailMutationTransaction

    /// The messages the local mailbox cache can still describe, or empty when it cannot.
    ///
    /// Resolved when the entry is built and never required. See
    /// ``InboxSessionModel/resolvedMessages(for:)`` for why an empty list is ordinary rather
    /// than a fault.
    let resolvedMessages: [MailMessage]

    /// Whether the existing undo path would act on this transaction right now.
    ///
    /// Passed in from the session rather than derived here, so a row cannot make itself
    /// actionable by being on screen.
    let isUndoable: Bool

    var id: UUID { transaction.id }

    init(
        transaction: MailMutationTransaction,
        resolvedMessages: [MailMessage] = [],
        isUndoable: Bool = false,
        rule: SenderRule? = nil
    ) {
        self.transaction = transaction
        self.resolvedMessages = resolvedMessages
        self.isUndoable = isUndoable
        self.rule = rule
    }

    // MARK: - Facts

    var occurredAt: Date { transaction.occurredAt }
    var operation: MailMutationOperation { transaction.operation }
    var status: MailMutationTransaction.ActivityStatus { transaction.activityStatus }

    /// What caused this operation.
    var origin: MailMutationOrigin { transaction.origin }

    /// Whether InboxSweep did this without anybody present.
    var wasAutomatic: Bool { transaction.origin.wasAutomatic }

    /// The rule this account still has for the rule that performed this, when it still has one.
    ///
    /// Passed in rather than looked up, so a row cannot reach the store. `nil` covers both "this
    /// was not a rule" and "the rule has since been deleted", and the wording below distinguishes
    /// them by asking ``origin`` rather than this.
    let rule: SenderRule?

    /// How many messages the user confirmed.
    var selectedCount: Int { transaction.selectedMessageCount }

    /// How many the provider confirmed when this ran.
    var confirmedCount: Int { transaction.confirmedMessageCount }

    /// How many were refused or never sent.
    var unchangedCount: Int { transaction.failedMessageCount }

    /// How many of an archive's messages have since been put back.
    var restoredCount: Int { transaction.restoredMessageCount }

    /// Whether this operation did only part of what was asked.
    var isPartial: Bool { transaction.isPartial }

    /// Whether the mailbox cache can still describe any of the messages involved.
    var hasResolvedMetadata: Bool { !resolvedMessages.isEmpty }

    /// Whether every message this operation still names came from one sender.
    ///
    /// ### Why this is derived and not stored
    ///
    /// A sender-reviewed archive is still an archive of *messages*. The sender was UI context —
    /// which screen the user was on — and the transaction deliberately has no field for it, in
    /// keeping with a record that names messages and describes none of them. Persisting an address
    /// so a row could read a little better would be putting mailbox content in a second file for a
    /// sentence, which is exactly the trade ``MailMutationTransaction`` refuses.
    ///
    /// So the question is asked of the *cache*, where that metadata already lives, and the answer
    /// is allowed to be no. It is only yes when the window can describe **every** message the
    /// transaction names and they agree — a partial answer would let the wording generalise from
    /// the six messages it could see to the fifteen it is counting.
    ///
    /// Partly-undone transactions are excluded for the same reason: their identifier list is
    /// narrower than the count in the headline, so the two would be about different sets.
    var cameFromOneSender: Bool {
        guard !resolvedMessages.isEmpty,
              resolvedMessages.count == transaction.succeededCount,
              transaction.succeededCount == confirmedCount
        else { return false }

        let keys = Set(resolvedMessages.map(\.sender.groupingKey))
        return keys.count == 1
    }

    // MARK: - Wording

    /// The headline: what was done, and to how many.
    ///
    /// A partial run says so in the headline rather than in a footnote, because "Archived 8 of
    /// 10 messages" and "Archived 10 messages" are different news and the second is the one
    /// somebody would remember.
    var title: String {
        switch operation {
        case .archive:
            if confirmedCount == 0 {
                return selectedCount == 1
                    ? "No message was archived"
                    : "No messages were archived"
            }
            if isPartial {
                return "Archived \(confirmedCount) of \(selectedCount) messages\(senderSuffix)\(ruleSuffix)"
            }
            return confirmedCount == 1
                ? "Archived 1 message\(senderSuffix)\(ruleSuffix)"
                : "Archived \(confirmedCount) messages\(senderSuffix)\(ruleSuffix)"

        case .restoreToInbox:
            if confirmedCount == 0 {
                return selectedCount == 1
                    ? "No message was put back"
                    : "No messages were put back"
            }
            if isPartial {
                return "Put \(confirmedCount) of \(selectedCount) messages back in your Inbox"
            }
            return confirmedCount == 1
                ? "Put 1 message back in your Inbox"
                : "Put \(confirmedCount) messages back in your Inbox"
        }
    }

    /// " from one sender", when the cache can say that much, and nothing otherwise.
    ///
    /// **"One sender", never the sender's name, and never "the sender".** The count is what was
    /// archived and the sender is context for it — writing "Archived everything from Example
    /// Sender" would claim an operation this app cannot perform, and naming the address here
    /// would put mail content in a headline for no gain over the message list below it.
    ///
    /// Nothing in this phrase says the sender was archived, that all of its mail was archived, or
    /// that anything it sends later is affected. It says these messages had one sender.
    private var senderSuffix: String { cameFromOneSender ? " from one sender" : "" }

    /// " by rule", when a local rule did this and not a person.
    ///
    /// In the headline rather than in a detail line, because it is the difference between news a
    /// user already knows and news they do not. "Archived 3 messages" beside a timestamp they were
    /// not at the keyboard for is a row that invites them to think they did it.
    ///
    /// It says *by rule*, never *by Gmail*. InboxSweep sent those requests; a row implying Gmail
    /// did it on its own would be the app disowning a change it made.
    private var ruleSuffix: String { wasAutomatic ? " by rule" : "" }

    /// Which local rule did this, when the account still has it.
    ///
    /// `nil` for everything a person confirmed. For a rule-driven row whose rule has since been
    /// deleted it still says so, because the archive happened and deleting the authorization
    /// afterwards does not make it anonymous.
    var ruleAttribution: String? {
        guard wasAutomatic else { return nil }
        guard let rule else {
            return "Your rule for this sender did this. The rule has since been deleted; the messages stayed archived."
        }
        return "Your rule for \(rule.senderDisplayValue) did this\(rule.isEnabled ? "" : ", and it is now turned off")."
    }

    /// The state line under the headline, or `nil` when there is nothing to add.
    ///
    /// Says where the *undo* stands, never where the mailbox stands.
    var statusSummary: String? {
        switch status {
        case .undoAvailable:
            return "Undo available"
        case .undoSuperseded where wasAutomatic:
            return "No undo for a rule"
        case .undoSuperseded:
            return "Undo superseded by a later archive"
        case .undoCompleted:
            return confirmedCount == 1 ? "Undone — put back in your Inbox" : "Undone — all put back in your Inbox"
        case .undoPartiallyCompleted:
            return isUndoable
                ? "Partly undone — \(restoredCount) of \(confirmedCount) put back, \(transaction.succeededCount) still archived"
                : "Partly undone — \(restoredCount) of \(confirmedCount) put back"
        case .restore:
            return nil
        case .nothingChanged:
            return "Nothing changed"
        }
    }

    /// The line naming what did not go through, or `nil` when everything did.
    ///
    /// Kept separate from ``statusSummary`` because they are different facts: one is about the
    /// messages Gmail refused at the time, the other about whether the operation can be
    /// reversed now.
    var unchangedSummary: String? {
        guard unchangedCount > 0 else { return nil }
        let noun = unchangedCount == 1 ? "message" : "messages"
        return operation == .archive
            ? "\(unchangedCount) \(noun) couldn't be archived"
            : "\(unchangedCount) \(noun) couldn't be put back"
    }

    /// What this row means, in a sentence, for the detail view.
    ///
    /// Careful about tense throughout. An archive *removed messages from the inbox at the time*;
    /// it does not claim they are still there, because the user's own mailbox is not something
    /// this record tracks.
    var explanation: String {
        switch operation {
        case .archive where confirmedCount == 0:
            return """
                InboxSweep asked Gmail to archive \(selectedCount == 1 ? "this message" : "these \(selectedCount) messages") \
                and none of them changed. Nothing left your Inbox.
                """

        case .archive:
            let base = """
                InboxSweep removed \(confirmedCount == 1 ? "this message" : "these \(confirmedCount) messages") \
                from your Inbox — one request to Gmail per message, each confirmed separately. \
                Archiving does not delete: they stayed in your Gmail account, in All Mail, and in search.
                """
            switch status {
            case .undoAvailable:
                return base + " InboxSweep can still put them back."
            case .undoCompleted:
                return base + " They were put back afterwards."
            case .undoPartiallyCompleted:
                return base + " \(restoredCount) of them were put back afterwards; the rest were not."
            case .undoSuperseded where wasAutomatic:
                // Not "superseded": nothing replaced it, because a rule-driven archive is never
                // offered as an undo in the first place. Saying so plainly is the point, since the
                // alternative is a row that reads as though an offer existed and was lost.
                return base + " " + SenderRuleRun.noUndoNote
            case .undoSuperseded:
                return base + " A later archive replaced this one as the undo InboxSweep offers, so there is no standing offer to reverse it."
            case .restore, .nothingChanged:
                return base
            }

        case .restoreToInbox where confirmedCount == 0:
            return """
                InboxSweep asked Gmail to put \(selectedCount == 1 ? "this message" : "these \(selectedCount) messages") \
                back in your Inbox and none of them changed.
                """

        case .restoreToInbox:
            return """
                InboxSweep put \(confirmedCount == 1 ? "this message" : "these \(confirmedCount) messages") back in \
                your Inbox — the undo of an earlier archive, sent to Gmail as a real request rather \
                than corrected only on this Mac.
                """
        }
    }

    /// What to say in place of message details the cache can no longer supply.
    ///
    /// Non-`nil` whenever fewer messages resolved than the transaction named, including when
    /// none did. It says *why*, because "InboxSweep no longer has the details" reads like data
    /// loss unless it is clear that never keeping them was the point.
    var metadataFallback: String? {
        let named = transaction.succeededCount
        guard named > 0, resolvedMessages.count < named else { return nil }

        if resolvedMessages.isEmpty {
            return """
                InboxSweep doesn't have the details of \(named == 1 ? "this message" : "these \(named) messages") \
                any more. It records what it changed, not the mail itself, and the loaded window no \
                longer covers them — reloading a wider window may bring them back.
                """
        }
        return """
            InboxSweep can still describe \(resolvedMessages.count) of \(named). It records what it \
            changed, not the mail itself, so the rest are outside the window currently loaded.
            """
    }
}

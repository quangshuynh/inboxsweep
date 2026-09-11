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
        isUndoable: Bool = false
    ) {
        self.transaction = transaction
        self.resolvedMessages = resolvedMessages
        self.isUndoable = isUndoable
    }

    // MARK: - Facts

    var occurredAt: Date { transaction.occurredAt }
    var operation: MailMutationOperation { transaction.operation }
    var status: MailMutationTransaction.ActivityStatus { transaction.activityStatus }

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
                return "Archived \(confirmedCount) of \(selectedCount) messages"
            }
            return confirmedCount == 1 ? "Archived 1 message" : "Archived \(confirmedCount) messages"

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

    /// The state line under the headline, or `nil` when there is nothing to add.
    ///
    /// Says where the *undo* stands, never where the mailbox stands.
    var statusSummary: String? {
        switch status {
        case .undoAvailable:
            return "Undo available"
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

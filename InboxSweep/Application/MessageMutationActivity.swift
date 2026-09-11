import Foundation

/// One archive-or-undo, as the screen showing it needs to understand it.
///
/// Exists as a value rather than as a handful of booleans on the session because the states are
/// mutually exclusive and the UI has to get that right: a screen that could be "running" and
/// "finished" at once is a screen that can offer Undo for something still in flight.
///
/// ### Why the result is a receipt and not a Boolean
///
/// A set of twelve does not succeed or fail. Eight can be archived and four refused, and that is
/// eight real changes to somebody's mailbox — so the finished phase carries the whole
/// ``MailArchiveSetReceipt`` and the screen reads per-message outcomes out of it. Collapsing it
/// to "failed" because four messages did not go through would tell the user the opposite of what
/// happened to the other eight.
///
/// It carries message *identifiers* and no mail. The confirmation list comes from the frozen
/// ``ArchiveSelectionSnapshot``, which already holds the subjects and dates — so this type never
/// becomes a second, quietly diverging copy of the mailbox.
nonisolated struct MessageMutationActivity: Equatable, Sendable, Identifiable {

    /// The logical mutation, shared with the frozen snapshot, the requests, and the durable
    /// transaction, so a repeated submission is recognisably the same one.
    let id: UUID

    let operation: MailMutationOperation

    /// The messages acted on, in the order they were confirmed.
    let messageIDs: [MailMessageID]

    /// The account they were acted on for. Shown nowhere; kept so a result cannot be applied to
    /// a window that has since changed accounts.
    let accountAddress: String

    private(set) var phase: Phase

    /// How many of ``messageIDs`` the provider has answered about so far.
    ///
    /// Progress, and only progress. It exists because a sequential set of thirty is a visibly
    /// long wait, and a Cancel button is only an honest offer if the user can see there is still
    /// something left to cancel.
    private(set) var completedCount: Int

    init(
        id: UUID,
        operation: MailMutationOperation,
        messageIDs: [MailMessageID],
        accountAddress: String,
        phase: Phase = .running,
        completedCount: Int = 0
    ) {
        self.id = id
        self.operation = operation
        self.messageIDs = messageIDs
        self.accountAddress = accountAddress
        self.phase = phase
        self.completedCount = completedCount
    }

    nonisolated enum Phase: Equatable, Sendable {

        /// The requests are going out one at a time. Nothing is claimed about the mailbox yet.
        case running

        /// Every message has an answer — which is not the same as every message having changed.
        ///
        /// `localRecordWarning` is non-`nil` in the one awkward case worth naming: the mailbox
        /// really did change, and this Mac could not write that down. Reporting that as a
        /// failure would tell the user the opposite of what happened to their mail, so it is
        /// carried on the *finished* case as a caveat.
        case finished(MailArchiveSetReceipt, localRecordWarning: String?)

        /// The operation was refused before any request went out, so nothing was attempted.
        ///
        /// Distinct from a finished run in which everything failed: there, the provider was
        /// asked and said no; here, the app never asked. Only the second is safe to describe as
        /// "nothing reached Gmail".
        case refused(MailMutationError)
    }

    var isRunning: Bool { phase == .running }

    /// The receipt, once there is one.
    var receipt: MailArchiveSetReceipt? {
        if case .finished(let receipt, _) = phase { return receipt }
        return nil
    }

    /// Whether every message the user confirmed did what was asked.
    ///
    /// Deliberately strict: a partial success is not a success, and a screen that treated it as
    /// one would stop mentioning the messages that did not move.
    var didSucceed: Bool { receipt?.isCompleteSuccess == true }

    /// Whether some messages changed and some did not.
    var isPartialSuccess: Bool { receipt?.isPartialSuccess == true }

    /// Whether anything at all changed in the mailbox.
    var changedAnything: Bool { (receipt?.confirmedCount ?? 0) > 0 }

    /// The single error to lead with, when there is one.
    ///
    /// `nil` as soon as anything was confirmed. A run that changed the mailbox does not have
    /// "an error" — it has a list of outcomes, and naming one of them as *the* error would hide
    /// the rest.
    var error: MailMutationError? {
        switch phase {
        case .running: nil
        case .refused(let error): error
        case .finished(let receipt, _): receipt.leadingFailure
        }
    }

    /// The caveat to show beside a success, when there is one.
    var localRecordWarning: String? {
        if case .finished(_, let warning) = phase { return warning }
        return nil
    }

    /// The single message, when this activity was about exactly one.
    var messageID: MailMessageID? {
        messageIDs.count == 1 ? messageIDs[0] : nil
    }

    /// Whether this activity is about `messageID` at all.
    func covers(_ messageID: MailMessageID) -> Bool {
        messageIDs.contains(messageID)
    }

    var selectedCount: Int { messageIDs.count }

    var confirmedCount: Int { receipt?.confirmedCount ?? 0 }

    var failedCount: Int { receipt?.failedCount ?? 0 }

    /// The messages that were never asked about — because the run was cancelled, or because a
    /// session-wide failure made every remaining request pointless.
    var notAttemptedCount: Int { receipt?.notAttemptedCount ?? 0 }

    /// The messages that can sensibly be offered again, with why they failed.
    ///
    /// Retryable failures and messages that were never attempted. A message refused for a
    /// reason repeating cannot fix — the account changed, Gmail no longer has it — is not in
    /// here, because offering a retry that is certain to fail again is not a recovery.
    var retryableMessageIDs: [MailMessageID] {
        guard let receipt else { return [] }
        return receipt.results
            .filter { ($0.outcome.error?.isRetryable ?? false) || !$0.outcome.wasAttempted }
            .map(\.messageID)
    }

    func settingPhase(_ phase: Phase) -> MessageMutationActivity {
        MessageMutationActivity(
            id: id,
            operation: operation,
            messageIDs: messageIDs,
            accountAddress: accountAddress,
            phase: phase,
            completedCount: completedCount
        )
    }

    func advancingProgress(to completed: Int) -> MessageMutationActivity {
        MessageMutationActivity(
            id: id,
            operation: operation,
            messageIDs: messageIDs,
            accountAddress: accountAddress,
            phase: phase,
            completedCount: min(max(completed, completedCount), messageIDs.count)
        )
    }

    // MARK: - Wording

    /// The line shown while the requests are going out.
    var progressDescription: String {
        guard selectedCount > 1 else {
            return "\(operation.inProgressVerbPhrase) one message. Waiting for Gmail to confirm…"
        }
        return """
            \(operation.inProgressVerbPhrase) \(selectedCount) messages, one at a time — \
            \(completedCount) of \(selectedCount) done. InboxSweep waits for Gmail to confirm each one.
            """
    }

    /// The line shown once every message has an answer.
    ///
    /// Three sentences rather than one, because the three outcomes a set can have are genuinely
    /// different news and a user should not have to count rows to find out which one they got.
    var resultDescription: String {
        guard let receipt else { return "" }

        switch operation {
        case .archive:
            if receipt.isCompleteSuccess {
                return selectedCount == 1
                    ? "Gmail confirmed: this message was archived. It has left your Inbox and is still in your mailbox."
                    : "Gmail confirmed all \(selectedCount): they have left your Inbox and are still in your mailbox."
            }
            if receipt.isPartialSuccess {
                return """
                    \(receipt.confirmedCount) of \(selectedCount) were archived and have left your Inbox. \
                    \(unchangedPhrase(receipt)) — those are still in your Inbox, exactly as they were.
                    """
            }
            return "Nothing was archived. \(unchangedPhrase(receipt)) — your Inbox is unchanged."

        case .restoreToInbox:
            if receipt.isCompleteSuccess {
                return selectedCount == 1
                    ? "Gmail confirmed: this message is back in your Inbox."
                    : "Gmail confirmed all \(selectedCount): they are back in your Inbox."
            }
            if receipt.isPartialSuccess {
                return """
                    \(receipt.confirmedCount) of \(selectedCount) are back in your Inbox. \
                    \(unchangedPhrase(receipt)) — those are still archived.
                    """
            }
            return "Nothing was put back. \(unchangedPhrase(receipt)) — those messages are still archived."
        }
    }

    /// Says what happened to the messages that did not change, distinguishing the two reasons.
    ///
    /// Plain interpolation rather than an inflected format string: these sentences are built as
    /// `String` and handed to `Text` as a value, where an `^[…](inflect:)` markup token would
    /// render literally rather than being applied.
    private func unchangedPhrase(_ receipt: MailArchiveSetReceipt) -> String {
        let refused = receipt.failedCount
        let untouched = receipt.notAttemptedCount

        switch (refused, untouched) {
        case (0, let untouched):
            return untouched == 1
                ? "1 message was never sent to Gmail"
                : "\(untouched) messages were never sent to Gmail"
        case (let refused, 0):
            return refused == 1 ? "Gmail refused 1 message" : "Gmail refused \(refused) messages"
        case (let refused, let untouched):
            return "Gmail refused \(refused), and \(untouched) were never sent"
        }
    }
}

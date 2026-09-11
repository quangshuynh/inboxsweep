import Foundation

/// One archive-or-undo, as the screen showing it needs to understand it.
///
/// Exists as a value rather than as a handful of booleans on the session because the states are
/// mutually exclusive and the UI has to get that right: a screen that could be "running" and
/// "succeeded" at once is a screen that can offer Undo for something still in flight.
///
/// It carries a message *identifier* and no message. The confirmation and the result are drawn
/// from the loaded window, which already holds the sender, subject, and date — so this type
/// never becomes a second, quietly diverging copy of the mail.
nonisolated struct MessageMutationActivity: Equatable, Sendable, Identifiable {

    /// The logical mutation, shared with the request and its record, so a repeated submission
    /// is recognisably the same one.
    let id: UUID

    let operation: MailMutationOperation

    /// The message acted on.
    let messageID: MailMessageID

    /// The account it was acted on for. Shown nowhere; kept so a result cannot be applied to a
    /// window that has since changed accounts.
    let accountAddress: String

    private(set) var phase: Phase

    init(
        id: UUID,
        operation: MailMutationOperation,
        messageID: MailMessageID,
        accountAddress: String,
        phase: Phase = .running
    ) {
        self.id = id
        self.operation = operation
        self.messageID = messageID
        self.accountAddress = accountAddress
        self.phase = phase
    }

    nonisolated enum Phase: Equatable, Sendable {

        /// The request is with Gmail. Nothing is claimed about the mailbox yet.
        case running

        /// Gmail confirmed the change.
        ///
        /// `localRecordWarning` is non-`nil` in the one awkward case worth naming: the mailbox
        /// really did change, and this Mac could not write that down. Reporting that as a
        /// failure would tell the user the opposite of what happened to their mail, so it is
        /// carried on the *success* case as a caveat.
        case succeeded(localRecordWarning: String?)

        /// It did not happen. Every ``MailMutationError`` states whether the mailbox was
        /// touched, and none of the ones reported here leaves that open.
        case failed(MailMutationError)
    }

    var isRunning: Bool { phase == .running }

    var didSucceed: Bool {
        if case .succeeded = phase { return true }
        return false
    }

    var error: MailMutationError? {
        if case .failed(let error) = phase { return error }
        return nil
    }

    /// The caveat to show beside a success, when there is one.
    var localRecordWarning: String? {
        if case .succeeded(let warning) = phase { return warning }
        return nil
    }

    func settingPhase(_ phase: Phase) -> MessageMutationActivity {
        MessageMutationActivity(
            id: id,
            operation: operation,
            messageID: messageID,
            accountAddress: accountAddress,
            phase: phase
        )
    }

    // MARK: - Wording

    /// The line shown while the request is out.
    var progressDescription: String {
        "\(operation.inProgressVerbPhrase) one message. Waiting for Gmail to confirm…"
    }

    /// The line shown once Gmail has confirmed.
    var successDescription: String {
        switch operation {
        case .archive:
            "Gmail confirmed: this message was archived. It has left your Inbox and is still in your mailbox."
        case .restoreToInbox:
            "Gmail confirmed: this message is back in your Inbox."
        }
    }
}

/// An archive that can still be taken back.
///
/// ### The undo lifetime, stated plainly
///
/// The offer lives in memory for as long as the session keeps this value, and this value is
/// discarded the moment the thing it refers to stops being certain:
///
/// - the undo succeeds, or is attempted and fails in a way that means the message is gone;
/// - another message is archived;
/// - the window is reloaded, the scope changes, or the account disconnects;
/// - the user dismisses the result;
/// - the app quits.
///
/// It is deliberately **not** persisted and deliberately **not** time-based. A timer would make
/// the offer expire at a moment the user cannot see, and restoring the offer after a relaunch
/// would mean holding out an undo for a mailbox state the app has not re-read and cannot
/// vouch for. When the offer is gone, the message is in Gmail's All Mail like any other
/// archived message, and moving it back is something Gmail itself does well.
nonisolated struct UndoableArchive: Equatable, Sendable {

    /// The archived message.
    let messageID: MailMessageID

    /// The account it was archived from. Checked again before the undo is sent.
    let accountAddress: String

    /// When the archive was confirmed. Shown, not enforced — there is no expiry.
    let archivedAt: Date
}

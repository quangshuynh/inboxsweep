import SwiftUI

/// The confirmation, progress, and result for archiving a set of messages, and the undo.
///
/// One sheet for all four states rather than an alert plus a banner, for a reason that is about
/// safety rather than tidiness: the sheet is modal, so the user cannot be editing a selection
/// while a confirmation about it is on screen, the button that starts the mutation cannot be
/// pressed twice, and the result (including the offer to undo) appears in the same place the
/// user was already looking. Nothing here can be reached by a proposal, a plan, or a dry run:
/// the only way in is a user ticking messages and pressing **Archive**.
///
/// ### It shows the frozen set, not the live one
///
/// Every message named on this screen comes from ``ArchiveSelectionSnapshot``, which was copied
/// out of the window when the user asked to review the set and does not change afterwards. If
/// the mailbox moves underneath (a page lands, a reload finishes) this list keeps describing
/// what the user is deciding about, and the session refuses the operation rather than executing
/// a different set. **The list on screen is the list that gets archived, or nothing does.**
///
/// A set of one is not special-cased into its own screen; the wording adapts and the machinery
/// does not.
struct ArchiveSelectionSheet: View {

    let session: InboxSessionModel

    /// The frozen set. Constant for the life of this sheet, by construction.
    let selection: ArchiveSelectionSnapshot

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let activity, activity.receipt != nil {
                        outcomeBreakdown(activity)
                    }
                    protectionWarning
                    messageList
                    stateSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 620, minHeight: 460, idealHeight: 560)
        .accessibilityIdentifier("archiveSheet.screen")
    }

    // MARK: - Derived state

    /// The activity, but only when it is about *this* confirmation.
    ///
    /// Matched on the operation identifier the frozen snapshot carries, so a result left over
    /// from another set (or from the undo of an earlier one) cannot be read as the outcome of
    /// this confirmation.
    private var activity: MessageMutationActivity? {
        guard let activity = session.mutationActivity else { return nil }
        guard activity.id == selection.id || isUndoOfThisSelection(activity) else { return nil }
        return activity
    }

    /// Whether `activity` is the undo of the archive this sheet performed.
    private func isUndoOfThisSelection(_ activity: MessageMutationActivity) -> Bool {
        activity.operation == .restoreToInbox
            && activity.messageIDs.allSatisfy(selection.messageIDs.contains)
    }

    private var isRunning: Bool { activity?.isRunning == true }

    /// Whether the undo offer on the session belongs to the archive this sheet performed.
    private var canUndo: Bool {
        guard !isRunning, let undoable = session.undoableArchive, undoable.isUndoable else { return false }
        return undoable.id == selection.id
    }

    private var count: Int { selection.count }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(headline, systemImage: headlineSymbol)
                .font(.title3.weight(.semibold))
                .lineLimit(3)
                .accessibilityIdentifier("archiveSheet.headline")

            Text(subhead)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var headline: String {
        guard let activity else {
            // Names the sender, because by this interval a set can arrive here from a
            // *sender-level* action and the user needs to see which sender's mail they are
            // about to change. It says "selected" rather than "from Example Sender" alone, so
            // the sentence cannot be read as an offer to archive the sender.
            return count == 1
                ? "Archive 1 selected message from \(selection.senderDisplayValue)?"
                : "Archive \(count) selected messages from \(selection.senderDisplayValue)?"
        }
        switch activity.phase {
        case .running:
            return "\(activity.operation.inProgressVerbPhrase) \(activity.selectedCount == 1 ? "one message" : "\(activity.selectedCount) messages")"
        case .refused(let error):
            return error.errorDescription ?? "That didn't work"
        case .finished(let receipt, _):
            if receipt.isCompleteSuccess {
                return activity.operation == .archive ? "Archived" : "Back in your Inbox"
            }
            if receipt.isPartialSuccess {
                // The headline the whole interval exists for: neither "done" nor "failed".
                return "\(receipt.confirmedCount) of \(receipt.selectedCount) \(activity.operation.completedVerbPhrase)"
            }
            return receipt.leadingFailure?.errorDescription ?? "Nothing changed"
        }
    }

    private var headlineSymbol: String {
        guard let activity else { return "archivebox" }
        switch activity.phase {
        case .running: return "arrow.triangle.2.circlepath"
        case .refused: return "exclamationmark.triangle"
        case .finished(let receipt, _):
            if receipt.isCompleteSuccess { return "checkmark.circle" }
            return receipt.isPartialSuccess ? "exclamationmark.circle" : "exclamationmark.triangle"
        }
    }

    private var subhead: String {
        guard let activity else {
            return count == 1
                ? """
                    Archiving removes the message from your Inbox. It does not delete it: the \
                    message stays in your Gmail account and remains searchable and in All Mail.
                    """
                : """
                    These \(count) messages will be removed from your Inbox. They will not be \
                    deleted: they stay in your Gmail account and remain searchable and in All Mail.
                    """
        }
        switch activity.phase {
        case .running: return activity.progressDescription
        case .refused(let error): return error.failureReason ?? ""
        case .finished: return activity.resultDescription
        }
    }

    /// The per-message tally, shown as soon as there is a result.
    ///
    /// Three counts rather than a verdict, because a set does not have a verdict. "10 selected,
    /// 8 archived, 2 failed" is the sentence a user can act on; "archiving failed" is not.
    private func outcomeBreakdown(_ activity: MessageMutationActivity) -> some View {
        GroupBox {
            HStack(spacing: 22) {
                tally("Selected", activity.selectedCount, "tray.full")
                tally(activity.operation == .archive ? "Archived" : "Restored", activity.confirmedCount, "checkmark.circle")
                if activity.failedCount > 0 {
                    tally("Failed", activity.failedCount, "exclamationmark.circle")
                }
                if activity.notAttemptedCount > 0 {
                    tally("Not sent", activity.notAttemptedCount, "minus.circle")
                }
                Spacer(minLength: 0)
            }
            .padding(6)
        }
        .accessibilityIdentifier("archiveSheet.outcomeBreakdown")
    }

    private func tally(_ label: String, _ value: Int, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
    }

    /// Said before the list, and only when the user put a protected message in the set by hand.
    ///
    /// No convenience action can produce this state: proposal-driven preselection never picks a
    /// protected message. So if this is on screen, somebody ticked it deliberately, and the
    /// warning's job is to make sure they meant to rather than to argue them out of it. It is
    /// their mail.
    @ViewBuilder
    private var protectionWarning: some View {
        if selection.containsProtectedMessages, activity == nil {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(selection.protectedMessages.count) of these are messages InboxSweep would normally hold back.")
                        .font(.callout.weight(.medium))
                    Text("""
                        They're starred, marked important, or look like part of a conversation. \
                        InboxSweep never picks these for you: you selected them, and it will \
                        archive them if you confirm. They are not deleted, and undo puts them back.
                        """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(.tint)
            }
            .accessibilityIdentifier("archiveSheet.protectionWarning")
        }
    }

    /// Every message in the set, named the way a person recognises mail.
    ///
    /// The whole list, never a summary with "and 34 more". A confirmation the user cannot read
    /// in full is not a confirmation, and the sheet scrolls.
    private var messageList: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("From \(selection.senderDisplayValue)")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(count == 1 ? "1 message" : "\(count) messages")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.bottom, 8)

                ForEach(Array(selection.messages.enumerated()), id: \.element.id) { index, message in
                    if index > 0 { Divider().padding(.vertical, 6) }
                    messageRow(message)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .accessibilityIdentifier("archiveSheet.messageList")
    }

    private func messageRow(_ message: ArchiveSelectionSnapshot.SelectedMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            outcomeIcon(for: message.id)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.subject ?? "No subject")
                    .font(.callout)
                    .foregroundStyle(message.subject == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(message.receivedAt.formatted(.dateTime.weekday(.abbreviated).day().month().year().hour().minute()))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let reason = message.protectionReason {
                        Label(protectionSummary(reason), systemImage: "shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(reason.explanation(count: 1))
                    }

                    // Only ever shown once there is a result: before that, every row is equally
                    // "about to be asked about", and decorating one would be a prediction.
                    if let note = outcomeNote(for: message.id) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What happened to one row, once anything has.
    @ViewBuilder
    private func outcomeIcon(for messageID: MailMessageID) -> some View {
        switch result(for: messageID)?.outcome {
        case .confirmed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.secondary)
        case .notAttempted:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        case .none:
            Image(systemName: "envelope").foregroundStyle(.secondary)
        }
    }

    /// The app's own wording for why a row did not change, never Gmail's response body.
    private func outcomeNote(for messageID: MailMessageID) -> String? {
        switch result(for: messageID)?.outcome {
        case .failed(let error): error.errorDescription
        case .notAttempted(let error):
            error == .cancelled ? "Not sent, you stopped it" : "Not sent"
        case .confirmed, .none: nil
        }
    }

    private func result(for messageID: MailMessageID) -> MailMessageMutationResult? {
        activity?.receipt?.results.first { $0.messageID == messageID }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch activity?.phase {
        case .none:
            scopeOfTheChange

        case .running:
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(
                    value: Double(activity?.completedCount ?? 0),
                    total: Double(max(activity?.selectedCount ?? 1, 1))
                )
                .progressViewStyle(.linear)
                .accessibilityIdentifier("archiveSheet.progress")

                // Honest about exactly what Stop can and cannot promise. The request currently
                // with Gmail may already have been applied and cannot be recalled; the ones
                // after it have not been sent and will not be.
                Text("""
                    Messages are sent to Gmail one at a time. Stopping now leaves everything \
                    already confirmed archived and sends nothing further: the request in flight \
                    can't be recalled.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .refused(let error):
            failureGuidance(error)

        case .finished(let receipt, let localRecordWarning):
            VStack(alignment: .leading, spacing: 12) {
                if let localRecordWarning {
                    // The distinction worth drawing carefully: Gmail did change the mailbox, and
                    // this Mac could not write that down. Reporting it as a failure would tell
                    // the user the opposite of what happened to their mail, and here it also
                    // means the undo will not be there after a relaunch, which is said out loud.
                    Label {
                        Text("""
                            Your mailbox was changed. \(localRecordWarning) The change is real. \
                            Undo still works while this is open, but it won't be offered again \
                            after you quit InboxSweep.
                            """)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                    }
                    .font(.callout)
                    .accessibilityIdentifier("archiveSheet.localRecordWarning")
                }

                if let failure = receipt.leadingFailure {
                    failureGuidance(failure)
                }

                if canUndo {
                    Text("""
                        Undo puts \(undoDescription) straight back in your Inbox. It's a real \
                        change in Gmail, not just here, and it stays available until you archive \
                        something else, including after you quit and reopen InboxSweep.
                        """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var undoDescription: String {
        let count = session.undoableArchive?.succeededCount ?? 0
        return count == 1 ? "this message" : "all \(count) of these messages"
    }

    @ViewBuilder
    private func failureGuidance(_ error: MailMutationError) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let suggestion = error.recoverySuggestion {
                Label(suggestion, systemImage: "lifepreserver")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("archiveSheet.recovery")
            }
            if error.isResolvedByGrantingPermission, session.archiveCapability.isUpgradable {
                Button {
                    session.requestArchivePermission()
                } label: {
                    Label("Grant the archive permission…", systemImage: "lock.open")
                }
                .accessibilityIdentifier("archiveSheet.grantPermissionButton")
            }
        }
    }

    /// Exactly what confirming does, and what it does not.
    ///
    /// Spelled out on the confirmation itself rather than left to documentation, because this is
    /// the screen where somebody decides.
    private var scopeOfTheChange: some View {
        VStack(alignment: .leading, spacing: 8) {
            point("tray.and.arrow.down", count == 1
                ? "Removes this one message from your Inbox."
                : "Removes these \(count) messages from your Inbox, and no others.")
            point("checkmark.shield", "Does not delete them. They stay in your mailbox, in All Mail, and in search.")
            point("envelope", "Does not mark them read, star them, or change any other label.")
            point("bubble.left.and.bubble.right", "Affects these messages only, not the rest of their conversations, and nothing else from this sender.")
            point("calendar.badge.clock", ArchiveSelectionSnapshot.senderScopeNote)
            point("list.number", "Sent to Gmail one message at a time, so each one gets its own answer.")
            point("arrow.uturn.backward", "Can be undone afterwards, including after you quit and reopen InboxSweep.")
        }
        .accessibilityIdentifier("archiveSheet.scope")
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 18)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            switch activity?.phase {
            case .none:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("archiveSheet.cancelButton")

                // Deliberately **not** the default action. It was, and that meant a stray
                // Return anywhere on this sheet archived somebody's mail: the one keystroke
                // people press to dismiss things was wired to the one control that changes a
                // mailbox. The unsubscribe review had already reached the same conclusion for
                // the same reason; this brings the two into line.
                //
                // Nothing is harder to do as a result. The button is the largest, most prominent
                // control on the sheet, and reaching it by keyboard is a Tab away.
                Button(count == 1 ? "Archive message" : "Archive \(count) messages") {
                    session.archiveSelection(selection)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canArchive(selection))
                .accessibilityIdentifier("archiveSheet.confirmButton")

            case .running:
                // A real Stop, because sequential execution makes it a real promise: it stops
                // before the next message rather than claiming to recall the one in flight.
                Button("Stop") { session.cancelMutation() }
                    .accessibilityIdentifier("archiveSheet.stopButton")

                Button("Archive") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                    .accessibilityIdentifier("archiveSheet.confirmButton")

            case .refused(let error):
                if error.isRetryable, session.canArchive(selection) {
                    Button("Try again") {
                        session.archiveSelection(selection)
                    }
                    .accessibilityIdentifier("archiveSheet.retryButton")
                }
                Button("Close") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("archiveSheet.doneButton")

            case .finished(let receipt, _):
                if canUndo {
                    Button {
                        session.undoLastArchive()
                    } label: {
                        Label(
                            session.undoableArchive?.succeededCount == 1 ? "Undo archive" : "Undo all",
                            systemImage: "arrow.uturn.backward"
                        )
                    }
                    .accessibilityIdentifier("archiveSheet.undoButton")
                }

                Button("Done") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("archiveSheet.doneButton")
                    .help(
                        receipt.failedCount > 0
                            ? "Closing leaves the messages Gmail refused in your Inbox. You can select them again."
                            : "Closes this. The undo offer stays available from the review screen."
                    )
            }
        }
        .padding(20)
    }

    private func finish() {
        session.dismissMutationActivity()
        dismiss()
    }

    /// A couple of words for a badge; the full sentence is the tooltip.
    private func protectionSummary(_ reason: CleanupExclusionReason) -> String {
        switch reason {
        case .starred: "Starred"
        case .markedImportant: "Important"
        case .protectedTopic(let topic): topic.displayName
        case .replyLikeSubject: "Conversation"
        case .newerThanCutoff, .amongNewestKept, .actionMovesNoMessages: "Held back"
        }
    }
}

import SwiftUI

/// The confirmation, progress, and result for archiving one message — and the undo.
///
/// One sheet for all four states rather than an alert plus a banner, for a reason that is about
/// safety rather than tidiness: the sheet is modal, so the message being confirmed cannot change
/// under the confirmation, the button that starts the mutation cannot be pressed twice, and the
/// result — including the offer to undo — appears in the same place the user was already
/// looking. Nothing here can be reached by a proposal, a plan, or a dry run: the only way in is
/// a user selecting one message and pressing Archive.
struct MessageArchiveSheet: View {

    let session: InboxSessionModel

    /// The message being archived, as the review screen has it.
    ///
    /// Passed in so the confirmation describes the message the user actually clicked. The
    /// mutation itself is driven entirely by ``MailMessage/id`` — the session re-checks that the
    /// identifier is still in the window before anything is sent, so a stale row here cannot
    /// become a mutation of the wrong message.
    let message: MailMessage

    /// The sender, as the review screen displays it.
    let senderDisplayValue: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    messageIdentity
                    stateSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 380, idealHeight: 440)
        .accessibilityIdentifier("archiveSheet.screen")
    }

    // MARK: - Derived state

    private var activity: MessageMutationActivity? {
        // Scoped to *this* message, so a result left over from another one cannot be read as
        // the outcome of this confirmation.
        guard let activity = session.mutationActivity,
              activity.messageID == message.id || session.undoableArchive?.messageID == message.id
        else { return nil }
        return activity
    }

    private var isRunning: Bool { activity?.isRunning == true }

    private var canUndo: Bool {
        session.undoableArchive?.messageID == message.id && !isRunning
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(headline, systemImage: headlineSymbol)
                .font(.title3.weight(.semibold))
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
        guard let activity else { return "Archive this message?" }
        switch activity.phase {
        case .running: return "\(activity.operation.inProgressVerbPhrase) one message"
        case .succeeded: return activity.operation == .archive ? "Archived" : "Back in your Inbox"
        case .failed: return activity.error?.errorDescription ?? "That didn't work"
        }
    }

    private var headlineSymbol: String {
        guard let activity else { return "archivebox" }
        switch activity.phase {
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var subhead: String {
        guard let activity else {
            return """
                Archiving removes the message from your Inbox. It does not delete it — the \
                message stays in your Gmail account and remains searchable and in All Mail.
                """
        }
        switch activity.phase {
        case .running: return activity.progressDescription
        case .succeeded: return activity.successDescription
        case .failed: return activity.error?.failureReason ?? ""
        }
    }

    /// The message, named by the metadata already on screen.
    ///
    /// Sender, subject, and received date — enough for the user to recognise which message they
    /// are about to change, and no more. There is no body to show and nowhere in the model to
    /// hold one.
    private var messageIdentity: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                identityRow("From", senderDisplayValue)
                identityRow("Subject", message.subject ?? "No subject")
                identityRow(
                    "Received",
                    message.receivedAt.formatted(.dateTime.weekday(.abbreviated).day().month().year().hour().minute())
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .accessibilityIdentifier("archiveSheet.messageIdentity")
    }

    private func identityRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch activity?.phase {
        case .none:
            scopeOfTheChange

        case .running:
            VStack(alignment: .leading, spacing: 10) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("archiveSheet.progress")
                // Said out loud rather than shown as a disabled Cancel button. Once Gmail has
                // the request it may already have applied it, and a Cancel that could not undo
                // what it interrupted would be a worse promise than none.
                Text("This can't be cancelled once Gmail has the request. InboxSweep waits for Gmail to confirm before changing anything on screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .succeeded(let localRecordWarning):
            VStack(alignment: .leading, spacing: 12) {
                if let localRecordWarning {
                    // The distinction worth drawing carefully: Gmail did change the mailbox,
                    // and this Mac could not write that down. Reporting it as a failure would
                    // tell the user the opposite of what happened to their mail.
                    Label {
                        Text("Your mailbox was changed. \(localRecordWarning) The change is real — reload to see the current state if anything looks out of date.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                    }
                    .font(.callout)
                    .accessibilityIdentifier("archiveSheet.localRecordWarning")
                }
                if canUndo {
                    Text("Undo puts this message straight back in your Inbox. It's a real change in Gmail, not just here, and it's offered until you close this or load the mailbox again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .failed(let error):
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
    }

    /// Exactly what confirming does, and what it does not.
    ///
    /// Spelled out on the confirmation itself rather than left to documentation, because this
    /// is the screen where someone decides.
    private var scopeOfTheChange: some View {
        VStack(alignment: .leading, spacing: 8) {
            point("tray.and.arrow.down", "Removes this one message from your Inbox.")
            point("checkmark.shield", "Does not delete it. It stays in your mailbox, in All Mail, and in search.")
            point("envelope", "Does not mark it read, star it, or change any other label.")
            point("bubble.left.and.bubble.right", "Affects this message only — not the rest of its conversation, and not anything else from this sender.")
            point("arrow.uturn.backward", "Can be undone from here straight afterwards.")
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

                Button("Archive message") {
                    session.archiveMessage(message.id)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canArchive(messageID: message.id))
                .accessibilityIdentifier("archiveSheet.confirmButton")

            case .running:
                // No Cancel here at all. Offering one would imply the request could be recalled.
                Button("Archive message") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                    .accessibilityIdentifier("archiveSheet.confirmButton")

            case .succeeded:
                if canUndo {
                    Button {
                        session.undoLastArchive()
                    } label: {
                        Label("Undo archive", systemImage: "arrow.uturn.backward")
                    }
                    .accessibilityIdentifier("archiveSheet.undoButton")
                }

                Button("Done") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("archiveSheet.doneButton")

            case .failed(let error):
                if canUndo {
                    Button {
                        session.undoLastArchive()
                    } label: {
                        Label("Try undo again", systemImage: "arrow.uturn.backward")
                    }
                    .accessibilityIdentifier("archiveSheet.undoButton")
                }

                if error.isRetryable, session.canArchive(messageID: message.id) {
                    Button("Try again") {
                        session.archiveMessage(message.id)
                    }
                    .accessibilityIdentifier("archiveSheet.retryButton")
                }

                Button("Close") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("archiveSheet.doneButton")
            }
        }
        .padding(20)
    }

    private func finish() {
        session.dismissMutationActivity()
        dismiss()
    }
}

import SwiftUI

/// The messages behind one sender's proposal, and what a chosen cleanup would do to each.
///
/// A proposal says "likely promotional clutter, 43 messages"; a preview says "38 would be
/// archived, 5 held back". Neither is checkable. This screen is where a user can actually look
/// at the 43, see the 5 and why they were spared, and decide whether the rules read their mail
/// the way they would have.
///
/// This screen is also the **only** place in the app that can change a mailbox, and it is
/// deliberately the one that already makes the user look at an individual message. Selecting a
/// row and pressing **Archive message…** opens a confirmation; nothing else does. A proposal, a
/// dry-run preview, a saved plan, and a sender row can all lead the user *here*, and every one
/// of them stops at this boundary — there is no control anywhere that archives a sender, a
/// selection, or a plan.
///
/// Everything else here still changes nothing. There is no message body to show —
/// ``MailMessage`` has nowhere to hold one — and the plan picker only changes which rows are
/// highlighted.
struct SenderMessageReviewView: View {

    let session: InboxSessionModel
    let summary: SenderSummary
    let proposal: SenderCleanupProposal?

    @Environment(\.dismiss) private var dismiss

    @State private var sortOrder: MessageReviewSortOrder = .newestFirst
    @State private var action: PlannedCleanupAction?
    @State private var showsOnlyAffected = false

    /// The row the user has picked out, if any.
    ///
    /// Single-selection: the archive action acts on one message, so a multi-selection would
    /// invite exactly the bulk operation this interval does not implement.
    @State private var selectedMessageID: MailMessage.ID?

    /// The message a confirmation is open for.
    ///
    /// Separate from ``selectedMessageID`` so that selecting a row never, by itself, puts the
    /// app one keystroke away from a mutation. Pressing the button is what fills this in.
    @State private var messagePendingArchive: MailMessage?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            messageTable
            Divider()
            footer
        }
        // The sheet takes its minimum width, so that is what has to fit all five columns —
        // an audit screen whose "under this plan" column is off the right edge audits nothing.
        .frame(minWidth: 900, idealWidth: 980, minHeight: 480, idealHeight: 620)
        .sheet(item: $messagePendingArchive) { message in
            MessageArchiveSheet(
                session: session,
                message: message,
                senderDisplayValue: summary.sender.displayValue
            )
        }
        .onAppear {
            // Seeded from the proposal so the screen opens on the plan the app actually
            // suggested, rather than on whichever action happens to be first in a menu.
            if action == nil { action = proposal?.kind.defaultPlannedAction }
        }
    }

    // MARK: - Derived state

    /// Recomputed on every render from the session's in-memory window.
    ///
    /// Cheap — it is filtering and sorting messages already loaded — and recomputing is what
    /// keeps the screen honest: there is no stored review that could still be showing a
    /// sender's old messages after a deeper load changed them.
    private var reviewed: [ReviewedMessage] {
        session.reviewedMessages(forSenderKey: summary.id, under: action, sortedBy: sortOrder)
    }

    private var visible: [ReviewedMessage] {
        showsOnlyAffected ? reviewed.filter(\.isAffectedByPlan) : reviewed
    }

    private var affectedCount: Int { reviewed.count(where: \.isAffectedByPlan) }
    private var protectedCount: Int { reviewed.count { $0.membership?.isProtected == true } }

    /// What this screen can and cannot do, said before anything else on it.
    ///
    /// Conditional because the old sentence — "no message is opened, moved, or changed" —
    /// stopped being true on this exact screen the moment archiving arrived. It is still true
    /// where the app genuinely cannot write, and saying so there is worth doing; saying it
    /// beside a working Archive button would be worse than saying nothing.
    private var disclaimer: String {
        let preamble = "These are the \(reviewed.count) messages InboxSweep has loaded from this sender."
        guard session.canOfferArchiving else {
            return "\(preamble) Nothing on this screen is sent to Gmail, and no message is opened, moved, or changed."
        }
        return """
            \(preamble) No message is opened — there is no message body to show. The only thing \
            that changes your mailbox is Archive, which acts on one message you select and \
            confirm, and can be undone.
            """
    }

    /// The selected row, when exactly one is selected and it is still in the window.
    private var selectedMessage: MailMessage? {
        guard let selectedMessageID else { return nil }
        return reviewed.first { $0.id == selectedMessageID }?.message
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Messages from \(summary.sender.displayValue)")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .accessibilityIdentifier("messageReview.screen")

            Label {
                Text(disclaimer)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("messageReview.disclaimer")
            } icon: {
                Image(systemName: session.canOfferArchiving ? "archivebox" : "eye")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Sort", selection: $sortOrder) {
                ForEach(MessageReviewSortOrder.allCases) { order in
                    Text(order.displayName).tag(order)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("messageReview.sortPicker")

            Picker("Preview", selection: $action) {
                Text("No plan").tag(PlannedCleanupAction?.none)
                ForEach(PlannedCleanupAction.offered) { offered in
                    Text(offered.displayName).tag(PlannedCleanupAction?.some(offered))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 280)
            .accessibilityIdentifier("messageReview.actionPicker")

            if action != nil {
                Toggle("Only affected", isOn: $showsOnlyAffected)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("messageReview.affectedOnlyToggle")
            }

            Spacer()

            archiveControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The app's only route to changing a mailbox.
    ///
    /// Shown at all only when the provider can write — the synthetic mailbox gets nothing, not
    /// a disabled button promising something it could never do. When the provider can write but
    /// the grant does not cover it, the control becomes the request for that permission, which
    /// keeps consenting and archiving two separate presses.
    @ViewBuilder
    private var archiveControl: some View {
        if session.canOfferArchiving {
            if session.archiveCapability.isGranted {
                Button {
                    // Read from the table, not from a proposal, a plan, or a recommendation.
                    // This assignment is the only thing in the app that opens a confirmation,
                    // and only a person pressing this button performs it.
                    messagePendingArchive = selectedMessage
                } label: {
                    Label("Archive message…", systemImage: "archivebox")
                }
                .disabled(selectedMessage == nil || session.isMutating)
                .help(
                    selectedMessage == nil
                        ? "Select one message to archive it. Archiving removes it from your Inbox; it does not delete it."
                        : "Asks you to confirm, then removes this one message from your Inbox. It is not deleted, and you can undo it."
                )
                .accessibilityIdentifier("messageReview.archiveButton")
            } else {
                Button {
                    session.requestArchivePermission()
                } label: {
                    Label("Enable archiving…", systemImage: "lock")
                }
                .disabled(session.isMutating)
                .help("InboxSweep needs one more Gmail permission before it can archive a message you pick. Nothing is archived by granting it.")
                .accessibilityIdentifier("messageReview.enableArchivingButton")
            }
        }
    }

    @ViewBuilder
    private var messageTable: some View {
        if visible.isEmpty {
            ContentUnavailableView(
                reviewed.isEmpty ? "No messages loaded" : "Nothing would be affected",
                systemImage: reviewed.isEmpty ? "tray" : "checkmark.shield",
                description: Text(
                    reviewed.isEmpty
                        ? "InboxSweep hasn't loaded any messages from this sender. Loading more of the mailbox may find some."
                        : "Every loaded message from this sender is either outside this action's scope or held back as protected."
                )
            )
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("messageReview.empty")
        } else {
            Table(visible, selection: $selectedMessageID) {
                TableColumn("Subject") { row in
                    Text(row.message.subject ?? "No subject")
                        .foregroundStyle(row.message.subject == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .fontWeight(row.message.isUnread ? .semibold : .regular)
                        .lineLimit(1)
                        .help(row.message.subject ?? "This message had no subject line.")
                }
                .width(min: 140, ideal: 230)

                TableColumn("Received") { row in
                    Text(row.message.receivedAt, format: .dateTime.day().month().year().hour().minute())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 115, ideal: 140)

                TableColumn("State") { row in
                    Text(row.stateLabels.isEmpty ? "Read" : row.stateLabels.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(row.stateLabels.joined(separator: ", "))
                }
                .width(min: 105, ideal: 140)

                TableColumn("Protection") { row in
                    if let reason = row.protectionReason, reason.isProtective {
                        Label {
                            Text(protectionSummary(reason))
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "shield")
                        }
                        .font(.callout)
                        .help(reason.explanation(count: 1))
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 95, ideal: 110)

                TableColumn(action.map { _ in "Under this plan" } ?? "Plan") { row in
                    membershipCell(for: row)
                }
                .width(min: 110, ideal: 140)
            }
            .tableStyle(.inset)
            .accessibilityIdentifier("messageReview.table")
        }
    }

    @ViewBuilder
    private func membershipCell(for row: ReviewedMessage) -> some View {
        if let action, let membership = row.membership {
            Label {
                Text(membership.shortDescription(for: action))
                    .lineLimit(1)
            } icon: {
                Image(systemName: membership.isAffected ? "arrow.right.circle" : (membership.isProtected ? "shield" : "minus.circle"))
            }
            .font(.callout)
            .foregroundStyle(membership.isAffected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .help(membership.explanation(for: action))
        } else {
            Text("No plan selected")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let action {
                Text("\(affectedCount) of ^[\(reviewed.count) loaded message](inflect: true) \(action.previewVerbPhrase); \(reviewed.count - affectedCount) would stay put, \(protectedCount) of them held back as protected.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("messageReview.summary")
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(CleanupPlan.disclaimer)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if session.canOfferArchiving {
                        // Said here because this screen shows both things at once: a preview of
                        // what a whole-sender cleanup *would* do, and a button that really
                        // archives one message. Leaving the difference implicit would be the
                        // easiest way for someone to believe the preview was about to run.
                        Text("Archiving one selected message is the only change InboxSweep can make, and it asks first. The preview above is not something it can carry out.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("messageReview.archiveScopeNote")
                    }
                }

                Spacer(minLength: 12)

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("messageReview.doneButton")
            }
        }
        .padding(16)
    }

    /// A couple of words for a narrow column; the full sentence is the tooltip.
    private func protectionSummary(_ reason: CleanupExclusionReason) -> String {
        switch reason {
        case .starred: "Starred"
        case .markedImportant: "Important"
        case .protectedTopic(let topic): topic.displayName
        case .replyLikeSubject: "Conversation"
        case .newerThanCutoff, .amongNewestKept, .actionMovesNoMessages: "—"
        }
    }
}

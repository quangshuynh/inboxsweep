import SwiftUI

/// The messages behind one sender's proposal, and what a chosen cleanup would do to each.
///
/// A proposal says "likely promotional clutter, 43 messages"; a preview says "38 would be
/// archived, 5 held back". Neither is checkable. This screen is where a user can actually look
/// at the 43, see the 5 and why they were spared, and decide whether the rules read their mail
/// the way they would have.
///
/// Nothing here opens, fetches, or changes anything. There is no message body to show —
/// ``MailMessage`` has nowhere to hold one — the plan picker only changes which rows are
/// highlighted, and the rows are not buttons because there is nothing for them to do.
struct SenderMessageReviewView: View {

    let session: InboxSessionModel
    let summary: SenderSummary
    let proposal: SenderCleanupProposal?

    @Environment(\.dismiss) private var dismiss

    @State private var sortOrder: MessageReviewSortOrder = .newestFirst
    @State private var action: PlannedCleanupAction?
    @State private var showsOnlyAffected = false

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
        .frame(minWidth: 720, idealWidth: 860, minHeight: 480, idealHeight: 620)
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

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Messages from \(summary.sender.displayValue)")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .accessibilityIdentifier("messageReview.screen")

            Label {
                Text("These are the \(reviewed.count) messages InboxSweep has loaded from this sender. Nothing on this screen is sent to Gmail, and no message is opened, moved, or changed.")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("messageReview.disclaimer")
            } icon: {
                Image(systemName: "eye")
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
            Table(visible) {
                TableColumn("Subject") { row in
                    Text(row.message.subject ?? "No subject")
                        .foregroundStyle(row.message.subject == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .fontWeight(row.message.isUnread ? .semibold : .regular)
                        .lineLimit(1)
                        .help(row.message.subject ?? "This message had no subject line.")
                }
                .width(min: 180, ideal: 300)

                TableColumn("Received") { row in
                    Text(row.message.receivedAt, format: .dateTime.day().month().year().hour().minute())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 130, ideal: 160)

                TableColumn("State") { row in
                    Text(row.stateLabels.isEmpty ? "Read" : row.stateLabels.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(row.stateLabels.joined(separator: ", "))
                }
                .width(min: 120, ideal: 190)

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
                .width(min: 110, ideal: 150)

                TableColumn(action.map { _ in "Under this plan" } ?? "Plan") { row in
                    membershipCell(for: row)
                }
                .width(min: 120, ideal: 170)
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
                Text(CleanupPlan.disclaimer)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

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

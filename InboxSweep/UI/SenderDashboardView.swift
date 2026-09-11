import SwiftUI

/// The connected dashboard: who sent the loaded mail, what InboxSweep makes of it, and why.
///
/// Every number on this screen describes the *loaded window*, not the whole mailbox, and the
/// header says so. Nothing here touches mail: the buttons load more of it, re-read it, preview
/// what a cleanup *would* reach, or disconnect the app.
struct SenderDashboardView: View {

    let snapshot: InboxSnapshot
    let session: InboxSessionModel

    /// Multi-selection, because a cleanup preview is a question about several senders at once.
    @State private var selectedSenderIDs: Set<SenderSummary.ID> = []
    @State private var filter: ProposalFilter = .all
    @State private var isInspectorPresented = false
    @State private var isPlanPresented = false
    @State private var isActivityPresented = false

    /// The sender whose loaded messages are being reviewed, if any.
    @State private var reviewedSender: SenderSummary?

    var body: some View {
        VStack(spacing: 0) {
            AccountSummaryHeader(snapshot: snapshot)
            if let notice = session.notice {
                SessionNoticeView(notice: notice)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            Divider()
            filterBar
            Divider()
            MailboxLoadBar(snapshot: snapshot, session: session)
            Divider()
            senderTable
            Divider()
            footer
        }
        .toolbar { toolbarContent }
        .inspector(isPresented: $isInspectorPresented) {
            Group {
                if let sender = inspectedSender {
                    SenderDetailView(
                        summary: sender,
                        proposal: snapshot.proposal(for: sender.id),
                        messages: session.loadedMessages(forSenderKey: sender.id),
                        onReviewMessages: { reviewedSender = sender }
                    )
                } else {
                    ContentUnavailableView(
                        selectedSenderIDs.isEmpty ? "No sender selected" : "\(selectedSenderIDs.count) senders selected",
                        systemImage: "person.crop.circle",
                        description: Text(
                            selectedSenderIDs.isEmpty
                                ? "Select a sender to see the reasoning behind its proposal."
                                : "Select a single sender to see its reasoning, or preview a cleanup for all of them."
                        )
                    )
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 340, max: 460)
        }
        .sheet(isPresented: $isPlanPresented) {
            CleanupPlanSheet(
                session: session,
                senderKeys: selectedSenderKeysInDisplayOrder,
                onReviewSender: { key in
                    isPlanPresented = false
                    reviewedSender = snapshot.senders.first { $0.id == key }
                }
            )
        }
        .sheet(isPresented: $isActivityPresented) {
            ActivityView(session: session)
        }
        .sheet(item: $reviewedSender) { sender in
            SenderMessageReviewView(
                session: session,
                summary: sender,
                proposal: snapshot.proposal(for: sender.id)
            )
        }
        .accessibilityIdentifier("dashboard.screen")
    }

    // MARK: - Derived state

    private var visibleSenders: [SenderSummary] {
        snapshot.senders(matching: filter)
    }

    /// The reasoning inspector answers a question about *one* sender, so it appears only when
    /// exactly one is selected rather than picking an arbitrary member of a multi-selection.
    private var inspectedSender: SenderSummary? {
        guard selectedSenderIDs.count == 1, let id = selectedSenderIDs.first else { return nil }
        return snapshot.senders.first { $0.id == id }
    }

    /// Selected senders in the order they appear on screen, so the preview reads top to bottom
    /// the way the table does rather than in a set's arbitrary order.
    private var selectedSenderKeysInDisplayOrder: [SenderSummary.ID] {
        snapshot.senders.map(\.id).filter(selectedSenderIDs.contains)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $filter) {
                ForEach(ProposalFilter.allCases) { option in
                    Label(option.displayName, systemImage: option.symbolName)
                        .tag(option)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("dashboard.filterPicker")

            Text("^[\(visibleSenders.count) sender](inflect: true)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            if !selectedSenderIDs.isEmpty {
                Button("Clear selection") { selectedSenderIDs = [] }
                    .buttonStyle(.link)
            }

            if let savedPlan = session.savedPlan, !savedPlan.isEmpty {
                Button {
                    // Resuming *selects* the saved senders and opens the preview. It carries
                    // nothing out, because there is nothing in this app that could.
                    selectedSenderIDs = Set(savedPlan.usableSelections.map(\.senderKey))
                    isPlanPresented = true
                } label: {
                    Label("^[\(savedPlan.usableSelections.count) saved sender](inflect: true)", systemImage: "bookmark")
                }
                .help("Reopens the preview with the senders and actions you saved. Nothing is carried out.")
                .accessibilityIdentifier("dashboard.resumeSavedPlanButton")
            }

            Button {
                isPlanPresented = true
            } label: {
                Label("Preview cleanup", systemImage: "eye")
            }
            .disabled(selectedSenderIDs.isEmpty)
            .help("Shows what a cleanup would reach for the selected senders. Nothing is changed and nothing is sent to Gmail.")
            .accessibilityIdentifier("dashboard.previewCleanupButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Table

    @ViewBuilder
    private var senderTable: some View {
        if visibleSenders.isEmpty {
            ContentUnavailableView(
                "Nothing to show",
                systemImage: filter.symbolName,
                description: Text(filter.emptyStateDescription)
            )
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("dashboard.emptyFilter")
        } else {
            Table(visibleSenders, selection: $selectedSenderIDs) {
                TableColumn("Sender") { summary in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(summary.sender.displayValue)
                            .lineLimit(1)
                        if let address = summary.sender.secondaryDisplayValue {
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .width(min: 170, ideal: 240)

                TableColumn("Proposal") { summary in
                    if let proposal = snapshot.proposal(for: summary.id) {
                        VStack(alignment: .leading, spacing: 1) {
                            ProposalBadge(proposal: proposal)
                            ProposalStrengthLabel(strength: proposal.strength, isCompact: true)
                        }
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 160, ideal: 200)

                TableColumn("Why") { summary in
                    if let reason = snapshot.proposal(for: summary.id)?.reasons.first {
                        Text(reason.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(reason.text)
                    }
                }
                .width(min: 180, ideal: 280)

                TableColumn("Messages") { summary in
                    Text(summary.messageCount, format: .number)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 80)

                TableColumn("Unread") { summary in
                    Text(summary.unreadCount, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(summary.unreadCount > 0 ? .primary : .tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 70)

                TableColumn("Latest") { summary in
                    Text(summary.newestReceivedAt, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 100, ideal: 120)
            }
            .tableStyle(.inset)
            .accessibilityIdentifier("dashboard.senderTable")
            .onChange(of: selectedSenderIDs) { _, newValue in
                isInspectorPresented = newValue.count == 1
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(snapshot.coverageDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("dashboard.coverageFooter")

            Spacer(minLength: 12)

            Text(PrivacyNotice.summary)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .help("InboxSweep suggests and previews. The only change it can make is archiving one message you open and confirm, from a sender's message review — nothing on this screen changes your mail.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Sort by", selection: Binding(
                get: { session.sortOrder },
                set: { session.sortOrder = $0 }
            )) {
                ForEach(SenderSortOrder.allCases) { order in
                    Text(order.displayName).tag(order)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("dashboard.sortPicker")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // Beside Reload rather than buried in the footer: "what has this app changed?" is a
            // question somebody asks about the mailbox in front of them, and it should be
            // answerable without hunting. It opens a reader — see ``ActivityView``.
            Button {
                isActivityPresented = true
            } label: {
                Label("Activity", systemImage: "clock.arrow.circlepath")
            }
            .help("Shows what InboxSweep has changed in this mailbox. Nothing is sent to Gmail by opening it.")
            .accessibilityIdentifier("dashboard.activityButton")

            Button {
                session.reload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("dashboard.reloadButton")

            Button {
                session.disconnect()
            } label: {
                Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .help("Signs InboxSweep out and forgets the stored authorization. Your mail is untouched.")
            .accessibilityIdentifier("dashboard.disconnectButton")
        }
    }
}

// Previews are development-only, and some of them run on the debug-only sample
// mailbox, so the whole block stays out of release builds.
#if DEBUG
#Preview {
    DashboardPreview()
}

/// Drives the dashboard preview from the synthetic mailbox.
private struct DashboardPreview: View {
    @State private var session = InboxSessionModel(
        provider: SampleMailProvider(),
        fetchRequest: MailFetchRequest(limit: 60)
    )

    var body: some View {
        Group {
            if let snapshot = session.state.snapshot {
                SenderDashboardView(snapshot: snapshot, session: session)
            } else {
                ProgressView()
            }
        }
        .frame(width: 1100, height: 640)
        .task { await session.connect().value }
    }
}
#endif

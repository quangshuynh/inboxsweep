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

    /// The sheet on screen, if any.
    ///
    /// **One** `@State` and **one** `.sheet` modifier, rather than one of each per destination.
    /// Stacking `.sheet` modifiers on a single view is not something SwiftUI honours: two
    /// happened to work, and adding a third for Activity made the new one silently never
    /// present — the button was there, the click landed, and nothing opened. An enum makes the
    /// exclusivity explicit, which is what it was all along: this screen shows at most one sheet.
    @State private var sheet: Sheet?

    /// The sheets the dashboard can present.
    private enum Sheet: Identifiable {

        /// The dry-run preview for the selected senders.
        case cleanupPlan

        /// What InboxSweep has changed in this mailbox.
        case activity

        /// One sender's loaded messages.
        case messageReview(SenderSummary)

        /// One sender's loaded messages, with the current preview's candidates already ticked.
        ///
        /// A separate case rather than an optional payload on ``messageReview``, so the two are
        /// distinct identities: opening a plain review and then a preselected one for the same
        /// sender really is a change of destination, and a shared identifier would leave SwiftUI
        /// showing the first sheet's already-built body with the preselection never applied.
        case senderCleanupReview(SenderSummary, SenderReviewCandidates)

        /// What one sender's own headers say about unsubscribing.
        ///
        /// A sibling of the review cases rather than something reachable from inside one: an
        /// unsubscribe is not a kind of archive, and putting it behind the archive review would
        /// have made it look like one.
        case unsubscribeOptions(SenderSummary)

        var id: String {
            switch self {
            case .cleanupPlan: "cleanupPlan"
            case .activity: "activity"
            case .messageReview(let summary): "messageReview-\(summary.id)"
            case .senderCleanupReview(let summary, let candidates):
                "senderCleanupReview-\(summary.id)-\(candidates.action.id)"
            case .unsubscribeOptions(let summary): "unsubscribeOptions-\(summary.id)"
            }
        }
    }

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
                        onReviewMessages: { sheet = .messageReview(sender) },
                        // Offered whether or not this session can write. The button's job is to
                        // move the user into a review state, which it does either way, and the
                        // review screen is the honest place to say whether archiving is available
                        // — it offers **Enable archiving…** on a read-only grant and nothing at
                        // all on the synthetic mailbox. Gating it here and not on the dry-run row
                        // would also have made two identically-worded controls behave differently.
                        onReviewCleanup: { openCleanupReview(for: sender, under: suggestedAction(for: sender.id)) },
                        // Offered whether or not this session can *perform* an unsubscribe, for
                        // the same reason the archive review is: what it opens is a reading, and
                        // the sheet is the honest place to say whether anything can be sent.
                        onReviewUnsubscribe: { sheet = .unsubscribeOptions(sender) },
                        unsubscribeOpportunity: session.unsubscribeOpportunity(forSenderKey: sender.id)
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
        .sheet(item: $sheet) { destination in
            switch destination {
            case .cleanupPlan:
                CleanupPlanSheet(
                    session: session,
                    senderKeys: selectedSenderKeysInDisplayOrder,
                    onReviewSender: { key in
                        // Replaces this sheet rather than opening a second one beside it.
                        sheet = snapshot.senders.first { $0.id == key }.map(Sheet.messageReview)
                    },
                    onReviewCleanupForSender: { key, action in
                        guard let sender = snapshot.senders.first(where: { $0.id == key }) else { return }
                        openCleanupReview(for: sender, under: action)
                    }
                )

            case .activity:
                ActivityView(session: session)

            case .messageReview(let sender):
                SenderMessageReviewView(
                    session: session,
                    summary: sender,
                    proposal: snapshot.proposal(for: sender.id)
                )

            case .senderCleanupReview(let sender, let candidates):
                SenderMessageReviewView(
                    session: session,
                    summary: sender,
                    proposal: snapshot.proposal(for: sender.id),
                    preselection: candidates
                )

            case .unsubscribeOptions(let sender):
                UnsubscribeOptionsSheet(session: session, summary: sender)
            }
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

    /// The action a sender-level entry point previews when nothing else has chosen one.
    ///
    /// The same seed the preview itself uses — the sender's own proposal — so pressing **Review
    /// messages to archive…** in the inspector and pressing it on that sender's preview row start
    /// from the same action rather than from two different defaults.
    private func suggestedAction(for key: SenderSummary.ID) -> PlannedCleanupAction {
        snapshot.proposal(for: key)?.kind.defaultPlannedAction ?? .keepNewest(count: 5)
    }

    /// Moves the user into a review, with the current preview's candidates ticked.
    ///
    /// **Derives and navigates. That is all it does.** The candidates come out of the window
    /// already in memory, nothing is sent, nothing is frozen, and no confirmation opens. The
    /// screen it opens is the same review any other route opens, with the same Archive button
    /// behind the same confirmation.
    private func openCleanupReview(for sender: SenderSummary, under action: PlannedCleanupAction) {
        sheet = .senderCleanupReview(
            sender,
            session.senderReviewCandidates(forSenderKey: sender.id, under: action)
        )
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
                    sheet = .cleanupPlan
                } label: {
                    Label("^[\(savedPlan.usableSelections.count) saved sender](inflect: true)", systemImage: "bookmark")
                }
                .help("Reopens the preview with the senders and actions you saved. Nothing is carried out.")
                .accessibilityIdentifier("dashboard.resumeSavedPlanButton")
            }

            Button {
                sheet = .cleanupPlan
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

            // `fixedSize` and the layout priority are what keep this control *present*. A footer
            // is a row of text competing for one line, and without them the link is the thing
            // that gets compressed when the coverage sentence or the privacy note is long —
            // squeezed to nothing on a narrow window, and intermittently unfindable in a UI test
            // while the coverage line is still saying "loading". A route into Activity that
            // disappears when a sentence beside it grows is not a route.
            activityLink
                .fixedSize()
                .layoutPriority(1)

            Text(PrivacyNotice.summary)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .help("InboxSweep suggests and previews. The only change it can make is archiving one message you open and confirm, from a sender's message review — nothing on this screen changes your mail.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The in-content way into Activity, beside the toolbar one rather than instead of it.
    ///
    /// ### Why a second route exists
    ///
    /// Because a toolbar is a place a control can be *hard to reach* — for a UI test driving the
    /// window from outside, and for anybody whose window is narrow enough that macOS collapses the
    /// toolbar into an overflow menu. "What has this app changed?" is a question worth being able
    /// to answer from the content itself, which is where the user is already looking.
    ///
    /// Deliberately small: a link in the footer beside the coverage line, not a banner. It is a
    /// drawer somebody opens occasionally, and giving it a prominent button would misrepresent
    /// how central it is.
    ///
    /// Opening it reaches no mailbox. See ``ActivityView``.
    private var activityLink: some View {
        Button {
            sheet = .activity
        } label: {
            Label("Activity", systemImage: "clock.arrow.circlepath")
                .font(.callout)
        }
        .buttonStyle(.link)
        .help("Shows what InboxSweep has changed in this mailbox. Nothing is sent to Gmail by opening it.")
        .accessibilityIdentifier("dashboard.activityLink")
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
                sheet = .activity
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

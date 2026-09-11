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
    /// present: the button was there, the click landed, and nothing opened. An enum makes the
    /// exclusivity explicit, which is what it was all along: this screen shows at most one sheet.
    @State private var sheet: Sheet?

    /// The sheets the dashboard can present.
    private enum Sheet: Identifiable {

        /// The dry-run preview for the selected senders.
        case cleanupPlan

        /// What InboxSweep has changed in this mailbox.
        case activity

        /// What InboxSweep has standing permission to do to it.
        ///
        /// A sibling of ``activity`` rather than a section of it: one says what the app did and
        /// cannot be acted on, the other says what it will do and is the only place that can be
        /// changed.
        case rules

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
            case .rules: "rules"
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
            ruleRunBanner
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
                        // review screen is the honest place to say whether archiving is
                        // available: it offers **Enable archiving…** on a read-only grant and
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

            case .rules:
                SenderRulesView(session: session)

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
    /// The same seed the preview itself uses (the sender's own proposal) so pressing **Review
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
                        // "None", not a dash glyph: a screen reader reads a word and cannot
                        // read a horizontal line, and this column is about an absence.
                        Text("None").foregroundStyle(.tertiary)
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
            // that gets compressed when the coverage sentence or the privacy note is long,
            // squeezed to nothing on a narrow window, and intermittently unfindable in a UI test
            // while the coverage line is still saying "loading". A route into Activity that
            // disappears when a sentence beside it grows is not a route.
            activityLink
                .fixedSize()
                .layoutPriority(1)

            rulesLink
                .fixedSize()
                .layoutPriority(1)

            Text(PrivacyNotice.summary)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .help("InboxSweep suggests and previews. The only change it can make is archiving one message you open and confirm, from a sender's message review. Nothing on this screen changes your mail.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The in-content way into Activity, beside the toolbar one rather than instead of it.
    ///
    /// ### Why a second route exists
    ///
    /// Because a toolbar is a place a control can be *hard to reach*, for a UI test driving the
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

    /// What the last rule pass did, reported where the user is looking.
    ///
    /// ### Why this is on the dashboard rather than only in Activity
    ///
    /// Because a rule is the one thing in this app that changes a mailbox while nobody is asking
    /// it to, and the user has to find out *at the time* rather than by opening a drawer. It is
    /// the same reasoning that put the undo offer on the review screen.
    ///
    /// It says three separate things and never merges them: what was archived, what was
    /// deliberately left behind, and what failed. The middle one matters most: mail a rule
    /// declined to archive is mail still sitting in somebody's Inbox from a sender they believe is
    /// handled, and it is by construction the mail most likely to need them.
    ///
    /// Dismissing it withdraws nothing. The changes are in Activity either way.
    @ViewBuilder
    private var ruleRunBanner: some View {
        if let run = session.ruleRun, run.isWorthShowing {
            VStack(alignment: .leading, spacing: 6) {
                if let archived = run.archivedSummary {
                    Label(archived, systemImage: "wand.and.stars.inverse")
                        .font(.callout.weight(.medium))
                        .accessibilityIdentifier("dashboard.ruleRun.archived")
                }
                if let protectedNote = run.protectedSummary {
                    bannerLine(protectedNote, identifier: "dashboard.ruleRun.protected")
                }
                if let deferred = run.deferredSummary {
                    bannerLine(deferred, identifier: "dashboard.ruleRun.deferred")
                }
                if let failure = run.failureSummary {
                    bannerLine(failure, identifier: "dashboard.ruleRun.failure")
                }
                if run.archivedCount > 0 {
                    bannerLine(SenderRuleRun.noUndoNote, identifier: "dashboard.ruleRun.noUndo")
                }

                HStack(spacing: 12) {
                    Button("Rules") { sheet = .rules }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("dashboard.ruleRun.rulesButton")

                    Button("Dismiss") { session.dismissRuleRun() }
                        .buttonStyle(.link)
                        .help("Hides this summary. It changes nothing, and the details stay in Activity.")
                        .accessibilityIdentifier("dashboard.ruleRun.dismissButton")

                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            // `.contain` rather than the default. An identifier on a stack of `Text`s invites
            // SwiftUI to merge the whole banner into one element, and a test asking whether the
            // no-undo sentence is present would then be asking about something that had been
            // folded away. This banner is a container of separately meaningful lines.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("dashboard.ruleRun")
        }
    }

    /// One wrapping sentence in the banner, bounded.
    ///
    /// ### Why the line limit, and why this is a `VStack` at all
    ///
    /// The first version put the sentences and the two buttons in one `HStack`. Measured by hand
    /// on the sample mailbox, that broke the dashboard outright: the header, the filter bar, and
    /// the load bar were pushed off the top of the window and the sender table was left clipped
    /// mid-row. Wrapping `Text`s laid out against whatever width two buttons leave over report an
    /// enormous intrinsic height, and the surrounding `VStack` honours it.
    ///
    /// Stacking vertically removes the competition entirely, and the line limit bounds what a
    /// long sentence can cost even so. A truncated line is not a loss here: every one of these is
    /// also in Activity, in full.
    ///
    /// It was found by hand because the UI suite could not run on this machine; a case asserting
    /// that `dashboard.coverageHeadline` is still present after a rule pass would have caught it.
    private func bannerLine(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }

    /// The in-content way into Rules, beside Activity and for the same reason.
    ///
    /// "What has this app changed?" and "what may it change without me?" are the two questions a
    /// person is entitled to be able to answer from the screen in front of them, and neither
    /// should depend on a toolbar that a narrow window collapses into an overflow menu.
    ///
    /// Opening it reaches no mailbox. See ``SenderRulesView``.
    private var rulesLink: some View {
        Button {
            sheet = .rules
        } label: {
            Label(
                session.senderRules.isEmpty ? "Rules" : "^[\(session.senderRules.count) rule](inflect: true)",
                systemImage: "wand.and.stars.inverse"
            )
            .font(.callout)
        }
        .buttonStyle(.link)
        .help("Shows what InboxSweep may do to this mailbox without asking. Nothing is sent to Gmail by opening it.")
        .accessibilityIdentifier("dashboard.rulesLink")
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
            // answerable without hunting. It opens a reader; see ``ActivityView``.
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

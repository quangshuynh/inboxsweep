import SwiftUI

/// The dry-run preview: what a set of cleanups *would* reach, if the app could carry them out.
///
/// It cannot, and the screen says so twice — once in the header and once in the footer beside
/// the totals. Every control here changes what is being previewed; none of them is a
/// confirmation, and there is deliberately no button whose label is a verb the app cannot
/// perform.
struct CleanupPlanSheet: View {

    let session: InboxSessionModel

    /// The senders to preview, in the order they appear on the dashboard.
    let senderKeys: [SenderSummary.ID]

    /// Opens the full message review for one sender.
    var onReviewSender: ((SenderSummary.ID) -> Void)?

    /// Opens the same review for one sender, starting from what that sender's row would reach.
    ///
    /// The sender-level entry point, offered from the dry run because this is the screen where
    /// somebody has just read "38 of 43 would be archived" and wants to get at the 38. It hands
    /// over the sender and the action being previewed and nothing else — the preview still cannot
    /// be carried out, and this does not make it carryable. It makes its result *editable*.
    var onReviewCleanupForSender: ((SenderSummary.ID, PlannedCleanupAction) -> Void)?

    @Environment(\.dismiss) private var dismiss

    /// The action chosen per sender. Seeded from each proposal's default and then owned here,
    /// so changing one sender's action re-previews without touching the dashboard.
    @State private var actions: [SenderSummary.ID: PlannedCleanupAction] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let savedPlan = session.savedPlan, savedPlan.isStale {
                stalenessNotice(savedPlan)
                Divider()
            }

            if plan.isEmpty {
                ContentUnavailableView(
                    "Nothing selected",
                    systemImage: "square.dashed",
                    description: Text("Choose one or more senders on the dashboard to preview a cleanup for them.")
                )
                .frame(maxHeight: .infinity)
            } else {
                entryList
            }

            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 460, idealHeight: 580)
        .onAppear(perform: seedActions)
    }

    // MARK: - Saved choices

    /// The current selections, in the order the sheet shows them.
    private var selections: [SavedCleanupSelection] {
        senderKeys.map {
            SavedCleanupSelection(senderKey: $0, action: actions[$0] ?? defaultAction(for: $0))
        }
    }

    /// Whether what is on screen is exactly what was last saved.
    private var matchesSavedPlan: Bool {
        session.savedPlan?.saved.selections == selections
    }

    /// Says what has moved since these choices were saved, and never quietly corrects it.
    ///
    /// A plan restored beside a changed ruleset is the case worth interrupting for: the
    /// reasoning the user was reading when they chose is not the reasoning on screen now.
    private func stalenessNotice(_ restored: RestoredCleanupPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(restored.isInvalidated ? "These saved choices are out of date" : "Something has changed since these choices were saved")
                    .font(.headline)
            } icon: {
                Image(systemName: restored.isInvalidated ? "exclamationmark.triangle" : "clock.arrow.circlepath")
                    .foregroundStyle(.orange)
            }

            ForEach(restored.staleness) { reason in
                Text(reason.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Nothing has been carried out. This is still a preview, and these choices only decide what it shows.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityIdentifier("cleanupPlan.stalenessNotice")
    }

    // MARK: - Plan

    /// Rebuilt on every render from the session's in-memory window.
    ///
    /// Cheap — it is counting messages already in memory — and recomputing keeps the preview
    /// honest: there is no stored plan that could still be on screen after the window changed
    /// underneath it.
    private var plan: CleanupPlan {
        session.cleanupPlan(
            for: senderKeys.map {
                CleanupPlanRequest(senderKey: $0, action: actions[$0] ?? defaultAction(for: $0))
            }
        )
    }

    /// What a sender starts on: whatever the user last saved for it, or the action the
    /// proposal suggests.
    ///
    /// A plan the rules have since invalidated is not used as a seed — resuming it would put
    /// last week's choice beside this week's reasoning without saying so.
    private func defaultAction(for key: SenderSummary.ID) -> PlannedCleanupAction {
        if let savedPlan = session.savedPlan, !savedPlan.isInvalidated,
           let saved = savedPlan.saved.action(forSenderKey: key) {
            return saved
        }
        return session.proposal(forSenderKey: key)?.kind.defaultPlannedAction ?? .reviewSubscription
    }

    private func seedActions() {
        for key in senderKeys where actions[key] == nil {
            actions[key] = defaultAction(for: key)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The screen's identifier sits on its title rather than on the containing stack:
            // an identifier applied to a container is pushed down onto its descendants and
            // erases theirs, which would take the disclaimer and the window notice with it.
            Text("Cleanup preview")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("cleanupPlan.screen")

            Label {
                // The identifier sits on the text itself: a `Label` is not its own
                // accessibility element here, so an identifier on the label would not be
                // findable — and this is the one sentence a test must be able to find.
                Text(CleanupPlan.disclaimer)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cleanupPlan.disclaimer")
            } icon: {
                Image(systemName: "eye")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var entryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(plan.entries) { entry in
                    CleanupPlanEntryView(
                        entry: entry,
                        action: Binding(
                            get: { actions[entry.sender.groupingKey] ?? entry.action },
                            set: { actions[entry.sender.groupingKey] = $0 }
                        ),
                        membership: session.reviewedMessages(
                            forSenderKey: entry.sender.groupingKey,
                            under: entry.action
                        ),
                        onReview: onReviewSender.map { review in
                            { review(entry.sender.groupingKey) }
                        },
                        onReviewCleanup: onReviewCleanupForSender.map { review in
                            { review(entry.sender.groupingKey, entry.action) }
                        }
                    )
                    .padding(16)

                    if entry.id != plan.entries.last?.id { Divider() }
                }
            }
        }
        .accessibilityIdentifier("cleanupPlan.entries")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !plan.isEmpty {
                HStack(spacing: 22) {
                    total(plan.totalAffectedMessageCount, "Would be affected")
                    total(plan.totalRetainedMessageCount, "Would stay put")
                    total(plan.totalProtectedMessageCount, "Held back as protected")
                    Spacer()
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("cleanupPlan.totals")

                Text(plan.window.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cleanupPlan.windowNotice")
            }

            HStack(spacing: 10) {
                Text("Nothing on this screen is sent to Gmail.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)

                Spacer()

                if session.savedPlan != nil {
                    Button("Forget saved choices") { session.discardSavedPlan() }
                        .accessibilityIdentifier("cleanupPlan.forgetButton")
                }

                Button(matchesSavedPlan ? "Choices saved" : "Remember these choices") {
                    session.savePlan(selections)
                }
                .disabled(plan.isEmpty || matchesSavedPlan)
                .help("Keeps which senders you picked and what you chose to preview for each, on this Mac. It schedules nothing — InboxSweep cannot carry a cleanup out.")
                .accessibilityIdentifier("cleanupPlan.saveButton")

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("cleanupPlan.doneButton")
            }
        }
        .padding(16)
    }

    private func total(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value, format: .number)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

/// One sender's row in the preview: what was chosen, what it reaches, and what it does not.
private struct CleanupPlanEntryView: View {

    let entry: CleanupPlanEntry
    @Binding var action: PlannedCleanupAction

    /// The sender's loaded messages, already classified under ``entry``'s action.
    let membership: [ReviewedMessage]

    /// Opens the full review for this sender.
    var onReview: (() -> Void)?

    /// Opens the full review for this sender with this row's affected messages already ticked.
    var onReviewCleanup: (() -> Void)?

    /// Whether the named messages are expanded.
    ///
    /// Collapsed by default: the counts are the summary, and a preview of ten senders that
    /// opened with every message listed would bury them.
    @State private var showsMessages = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    // The entry's identifier sits on its title rather than on the containing
                    // stack: SwiftUI pushes an identifier down onto its descendants and erases
                    // theirs, which would take the disclosure and the review link with it.
                    Text(entry.sender.displayValue)
                        .font(.headline)
                        .lineLimit(1)
                        .accessibilityIdentifier("cleanupPlan.entry")
                    Text(entry.proposalKind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Picker("Preview action", selection: $action) {
                    ForEach(PlannedCleanupAction.offered) { offered in
                        Text(offered.displayName).tag(offered)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }

            outcome
            messageMembership

            if entry.contradictsProtection {
                Label {
                    Text("InboxSweep suggested keeping this sender. The preview still excludes its protected messages, but the rest are counted above.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var outcome: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.callout)

            if !entry.exclusions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entry.exclusions) { exclusion in
                        Label {
                            Text(exclusion.explanation)
                        } icon: {
                            Image(systemName: exclusion.isProtective ? "shield" : "minus.circle")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Names the individual messages behind the counts above.
    ///
    /// "43 would be archived, 7 would stay put" is not a claim anyone can check. This is where
    /// the 43 and the 7 become a list — which is the difference between a preview the user is
    /// asked to trust and one they can audit.
    @ViewBuilder
    private var messageMembership: some View {
        if !membership.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    DisclosureGroup("Which messages?", isExpanded: $showsMessages) { EmptyView() }
                        .font(.callout)
                        .fixedSize()
                        .accessibilityIdentifier("cleanupPlan.membershipDisclosure")

                    if let onReview {
                        Button("Review all…", action: onReview)
                            .buttonStyle(.link)
                            .font(.callout)
                            .accessibilityIdentifier("cleanupPlan.reviewButton")
                    }
                    if let onReviewCleanup, entry.action.movesMessages {
                        Button("Review messages to archive…", action: onReviewCleanup)
                            .buttonStyle(.link)
                            .font(.callout)
                            .help("Opens the review with the messages named above already ticked, so you can check them, change the list, and decide. It archives nothing, and never ticks a protected message.")
                            .accessibilityIdentifier("cleanupPlan.reviewCleanupButton")
                    }
                    Spacer()
                }

                if showsMessages {
                    VStack(alignment: .leading, spacing: 10) {
                        membershipList(
                            "Would affect",
                            symbol: "arrow.right.circle",
                            rows: membership.filter(\.isAffectedByPlan),
                            emptyText: "No loaded message from this sender \(entry.action.previewVerbPhrase)."
                        )
                        membershipList(
                            "Protected / retained",
                            symbol: "shield",
                            rows: membership.filter { !$0.isAffectedByPlan },
                            emptyText: "Every loaded message from this sender would be affected."
                        )
                    }
                    .padding(.leading, 18)
                    .accessibilityIdentifier("cleanupPlan.membershipLists")
                }
            }
        }
    }

    /// One named group, capped so a sender with four hundred messages does not become the
    /// whole sheet. The review screen is where the full list lives.
    @ViewBuilder
    private func membershipList(
        _ title: String,
        symbol: String,
        rows: [ReviewedMessage],
        emptyText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("\(title) (\(rows.count))", systemImage: symbol)
                .font(.caption.weight(.semibold))

            if rows.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(rows.prefix(Self.namedMessageLimit)) { row in
                    Text(messageLine(for: row))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(messageLine(for: row))
                }
                if rows.count > Self.namedMessageLimit {
                    Text("…and \(rows.count - Self.namedMessageLimit) more. Open the review to see them all.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private static let namedMessageLimit = 6

    /// Subject, date, and — for a retained message — why it was retained.
    private func messageLine(for row: ReviewedMessage) -> String {
        let subject = row.message.subject ?? "No subject"
        let date = row.message.receivedAt.formatted(.dateTime.day().month().year())
        guard let reason = row.membership?.reason else { return "\(subject) · \(date)" }
        return "\(subject) · \(date) — \(reason.explanation(count: 1))"
    }

    /// The one sentence a reader should take away, phrased conditionally throughout.
    private var headline: String {
        guard entry.action.movesMessages else {
            return "No message would be moved — this is a prompt to look at the subscription itself."
        }
        return "\(entry.affectedMessageCount) of \(ProposalPhrasing.loadedMessages(entry.loadedMessageCount)) "
            + "\(entry.action.previewVerbPhrase); \(entry.retainedMessageCount) would stay put."
    }
}

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

    @Environment(\.dismiss) private var dismiss

    /// The action chosen per sender. Seeded from each proposal's default and then owned here,
    /// so changing one sender's action re-previews without touching the dashboard.
    @State private var actions: [SenderSummary.ID: PlannedCleanupAction] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

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

    private func defaultAction(for key: SenderSummary.ID) -> PlannedCleanupAction {
        session.proposal(forSenderKey: key)?.kind.defaultPlannedAction ?? .reviewSubscription
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
                        )
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

            HStack {
                Text("Nothing on this screen is sent to Gmail.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)

                Spacer()

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.sender.displayValue)
                        .font(.headline)
                        .lineLimit(1)
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
        .accessibilityIdentifier("cleanupPlan.entry")
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

    /// The one sentence a reader should take away, phrased conditionally throughout.
    private var headline: String {
        guard entry.action.movesMessages else {
            return "No message would be moved — this is a prompt to look at the subscription itself."
        }
        return "\(entry.affectedMessageCount) of \(ProposalPhrasing.loadedMessages(entry.loadedMessageCount)) "
            + "\(entry.action.previewVerbPhrase); \(entry.retainedMessageCount) would stay put."
    }
}

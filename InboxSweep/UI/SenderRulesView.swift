import SwiftUI

/// Every rule this account has, what each one does, and the two ways to end one.
///
/// The place a user goes to answer "what have I told InboxSweep to do without asking me?". It is
/// a first-class screen rather than a section of Activity for a reason that is about the two
/// questions being different: Activity says what the app *did*, in the past, and cannot be acted
/// on; this says what it *will* do, and is the only screen where that can be changed.
///
/// Nothing here reaches a mailbox. Listing rules reads a local file, toggling one rewrites that
/// file, and deleting one removes an entry from it. None of the three sends anything to Gmail,
/// and none of them changes a message that a rule has already archived.
struct SenderRulesView: View {

    let session: InboxSessionModel

    @Environment(\.dismiss) private var dismiss

    /// The rule a deletion confirmation is open for.
    ///
    /// Deleting is confirmed and toggling is not, deliberately. Turning a rule off is reversible
    /// in one press and is the safe direction; deleting throws away a decision the user made on a
    /// review screen, and it cannot be taken back.
    @State private var pendingDeletion: SenderRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 420, idealHeight: 540)
        // Escape closes it, which is what every macOS sheet does and what this one did not.
        // Safe here because closing changes nothing: the only exits from this screen are Done and
        // Escape, and neither touches a mailbox. The sheets that *can* act keep Escape bound to
        // their own Cancel, which backs out of the confirmation rather than out of the sheet.
        .onExitCommand { dismiss() }
        .accessibilityIdentifier("rules.screen")
        .confirmationDialog(
            pendingDeletion.map { "Delete the rule for \($0.senderDisplayValue)?" } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete rule", role: .destructive) {
                if let rule = pendingDeletion { session.deleteRule(rule) }
                pendingDeletion = nil
            }
            .accessibilityIdentifier("rules.confirmDeleteButton")

            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("""
                Future mail from this sender stays in your Inbox. Mail this rule already archived \
                stays archived, and its entries stay in Activity.
                """)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rules")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("rules.title")

            Text("""
                Rules are the only thing InboxSweep does to your mail without asking first, and \
                you created each one yourself. They live on this Mac, they are not Gmail filters, \
                and they only run while InboxSweep is loading mail.
                """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("rules.scopeNote")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if session.senderRules.isEmpty {
            ContentUnavailableView(
                "No rules",
                systemImage: "wand.and.stars.inverse",
                description: Text("""
                    InboxSweep has no standing permission to change anything in this mailbox. \
                    You can create a rule from a sender's message review, and it will ask you \
                    to read exactly what it would do first.
                    """)
            )
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("rules.empty")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(session.senderRules) { rule in
                        row(for: rule)
                        Divider()
                    }
                }
                .accessibilityIdentifier("rules.list")
            }
        }
    }

    private func row(for rule: SenderRule) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.senderDisplayValue)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Text(rule.senderKey)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .accessibilityIdentifier("rules.row.senderKey")

                Text(rule.action.description)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rules.row.action")

                Text(executionLine(for: rule))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rules.row.executionNote")

                Text("Created \(rule.createdAt, format: .dateTime.day().month().year())")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                Toggle("Enabled", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { session.setRule(rule, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(rule.isEnabled ? "Turns this rule off. Nothing else changes." : "Turns this rule back on.")
                .accessibilityLabel("Enable the rule for \(rule.senderDisplayValue)")
                .accessibilityIdentifier("rules.row.enabledToggle")

                Button("Delete") { pendingDeletion = rule }
                    .buttonStyle(.link)
                    .help("Removes this rule. Mail it has already archived stays archived.")
                    .accessibilityLabel("Delete the rule for \(rule.senderDisplayValue)")
                    .accessibilityIdentifier("rules.row.deleteButton")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A row is a container of separately meaningful lines, not one label; see the rule-run
        // banner for what the default does to a stack of `Text`s carrying an identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rules.row")
    }

    /// What this particular rule can do right now, which is not always what it says it does.
    ///
    /// Three states, and the middle one is the one worth spelling out: a rule the user turned off
    /// is not gone, and a rule this session cannot carry out is not broken. Saying "archives new
    /// mail" beside either would be the screen claiming something is happening that is not.
    private func executionLine(for rule: SenderRule) -> String {
        guard rule.isEnabled else {
            return "Turned off. It matches nothing until you turn it back on, and it is not deleted."
        }
        guard session.canExecuteRules else {
            return """
                Saved, and not running: InboxSweep can't archive in this session. It starts \
                working again as soon as archiving is available.
                """
        }
        return rule.executionDescription
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let warning = session.ruleWriteWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rules.warning")
            }

            Text(SenderRule.Action.boundaryNote)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("rules.boundaryNote")

            HStack {
                Text("InboxSweep keeps at most \(SenderRuleRetention.ruleLimit) rules per account.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("rules.doneButton")
            }
        }
        .padding(20)
    }
}

/// Shown when a rule review could not be derived, instead of an empty sheet or a silent no-op.
///
/// There are exactly three reasons ``InboxSessionModel/makeSenderRuleReview(forSenderKey:)``
/// returns `nil`, and all three are things the user can act on. A button that opened nothing would
/// leave them pressing it again; a button that was merely disabled would leave them guessing which
/// of the three it was.
///
/// The existing-rule case is the common one, and it is not a failure at all: it shows the rules
/// they already have, which is what somebody asking for a rule on a sender they already ruled on
/// actually wants.
struct RuleUnavailableSheet: View {

    let session: InboxSessionModel
    let summary: SenderSummary

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if session.rule(forSenderKey: summary.id) != nil {
            SenderRulesView(session: session)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Label(title, systemImage: "wand.and.stars.inverse")
                    .font(.title3.weight(.semibold))

                Text(explanation)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ruleUnavailable.explanation")

                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("ruleUnavailable.doneButton")
                }
            }
            .padding(24)
            .frame(minWidth: 420, idealWidth: 480)
            .accessibilityIdentifier("ruleUnavailable.screen")
        }
    }

    private var title: String {
        session.isAtRuleCapacity ? "No room for another rule" : "This sender can't have a rule"
    }

    private var explanation: String {
        if session.isAtRuleCapacity {
            return SenderRuleFailure.tooManyRules.message
        }
        if summary.id == EmailAddress.unknownGroupingKey {
            return SenderRuleFailure.senderNotIdentifiable.message
        }
        return SenderRuleFailure.reviewIsStale.message
    }
}

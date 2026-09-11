import SwiftUI

/// The screen a rule has to pass through before it exists.
///
/// ### What it is for
///
/// A rule is the only authorization in InboxSweep that outlives the screen that granted it.
/// Everything else the app can do is a single confirmed act: archive these twelve, send this one
/// request. A rule keeps acting, on mail nobody has seen, until somebody turns it off. That
/// deserves its own screen rather than a checkbox on the archive confirmation, and reusing the
/// archive confirmation for it would be the specific mistake of making "archive these messages"
/// and "archive this sender's mail from now on" look like one decision with an extra option.
///
/// So this screen says six things before it offers anything, in this order:
///
/// 1. the **exact address** it will match, not the display name;
/// 2. the **exact action**, in a sentence with no verb the rule cannot perform;
/// 3. **when it can run**, which is only while InboxSweep is loading mail;
/// 4. that **existing mail is not touched**, now or ever;
/// 5. what it **will not do to protected mail**;
/// 6. **how to end it**.
///
/// Opening it creates nothing, and closing it leaves nothing behind. See
/// ``SenderRuleReviewSnapshot``.
struct SenderRuleReviewSheet: View {

    let session: InboxSessionModel
    let review: SenderRuleReviewSnapshot

    @Environment(\.dismiss) private var dismiss

    /// Whether the second, dedicated confirmation is on screen.
    ///
    /// The same two-press shape the unsubscribe review uses, and for a related reason: the first
    /// press means "I have read this", and the second means "create it". One press that did both
    /// would make the reading optional.
    @State private var isConfirming = false

    /// Set once the rule has been created, so the sheet reports rather than re-offers.
    @State private var created = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identityBox
                    whatItDoes
                    whenItRuns
                    existingMail
                    protection
                    revocation
                    if !review.canExecute { cannotExecuteYet }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 600)
        .accessibilityIdentifier("ruleReview.screen")
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Create a rule for \(review.senderDisplayValue)")
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .accessibilityIdentifier("ruleReview.title")

            Text("Nothing is created until you confirm below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ruleReview.subtitle")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    /// The address, printed exactly, because that is the thing the rule matches.
    ///
    /// Monospaced and selectable for the same reason the unsubscribe review prints its
    /// destination that way: a person checking whether this is the right sender is reading
    /// character by character, and a proportional font makes `rn` and `m` the same picture.
    private var identityBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This rule matches one exact address", systemImage: "person.crop.square")
                .font(.callout.weight(.medium))

            Text(review.senderKey)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ruleReview.senderKey")

            Text("""
                Only mail from this address matches. A sender with a similar address, a similar \
                name, or a similar subject does not, and changing this sender's display name \
                changes nothing.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ruleReview.matchingNote")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var whatItDoes: some View {
        section(
            title: "What it does",
            systemImage: "archivebox",
            body: review.action.description,
            identifier: "ruleReview.action"
        ) {
            Text(SenderRule.Action.boundaryNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ruleReview.boundaryNote")
        }
    }

    private var whenItRuns: some View {
        section(
            title: "When it runs",
            systemImage: "clock",
            body: review.action.executionDescription,
            identifier: "ruleReview.executionNote"
        )
    }

    private var existingMail: some View {
        section(
            title: "Your existing mail",
            systemImage: "tray.full",
            body: SenderRuleReviewSnapshot.existingMailNote,
            identifier: "ruleReview.existingMailNote"
        ) {
            if review.loadedMessageCount > 0 {
                Text(
                    review.loadedMessageCount == 1
                        ? "InboxSweep has 1 message from this sender loaded right now. This rule will not touch it."
                        : "InboxSweep has \(review.loadedMessageCount) messages from this sender loaded right now. This rule will not touch any of them."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ruleReview.loadedCount")
            }
        }
    }

    private var protection: some View {
        section(
            title: "Mail it will not archive",
            systemImage: "shield.lefthalf.filled",
            body: SenderRuleReviewSnapshot.protectionNote,
            identifier: "ruleReview.protectionNote"
        )
    }

    private var revocation: some View {
        section(
            title: "Turning it off",
            systemImage: "xmark.circle",
            body: SenderRuleReviewSnapshot.revocationNote,
            identifier: "ruleReview.revocationNote"
        ) {
            Text(SenderRuleRun.noUndoNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ruleReview.noUndoNote")
        }
    }

    /// Said when the rule can be created but not yet carried out.
    ///
    /// A rule is a durable decision, so it is recorded whether or not today's session could act on
    /// it. What must not happen is the app taking the authorization and quietly doing nothing with
    /// it, so the state is named here and named again on every row in Rules.
    private var cannotExecuteYet: some View {
        Label {
            Text("""
                InboxSweep can't archive in this session, so this rule will be saved and will not \
                run yet. On the sample mailbox it never will; on a real account it starts working \
                once you enable archiving.
                """)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("ruleReview.cannotExecuteNote")
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func section(
        title: String,
        systemImage: String,
        body: String,
        identifier: String,
        @ViewBuilder extra: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
            Text(body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
            extra()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let warning = session.ruleWriteWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ruleReview.warning")
            }

            if created {
                Label("Rule created. It is listed in Rules, where you can turn it off or delete it.", systemImage: "checkmark.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ruleReview.created")
            } else if isConfirming {
                Text("Create this rule? It will archive future mail from \(review.senderKey) whenever InboxSweep loads it.")
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ruleReview.confirmPrompt")
            }

            HStack(spacing: 12) {
                Spacer()

                if created {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("ruleReview.doneButton")
                } else {
                    Button(isConfirming ? "Not now" : "Cancel") {
                        // Backs out of the confirmation first, and out of the sheet second.
                        // Neither has created anything: there is one call to `createRule` in this
                        // file and it is below.
                        if isConfirming { isConfirming = false } else { dismiss() }
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("ruleReview.cancelButton")

                    if isConfirming {
                        Button("Create rule") {
                            Task {
                                await session.createRule(from: review).value
                                created = session.rule(forSenderKey: review.senderKey) != nil
                                isConfirming = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!session.canCreateRule(from: review))
                        .accessibilityIdentifier("ruleReview.confirmButton")
                    } else {
                        Button("Create rule…") { isConfirming = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(!session.canCreateRule(from: review))
                            .help("Opens a final confirmation. Nothing is created until you press it.")
                            .accessibilityIdentifier("ruleReview.actionButton")
                    }
                }
            }
        }
        .padding(20)
    }
}

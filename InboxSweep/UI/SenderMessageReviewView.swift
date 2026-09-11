import SwiftUI

/// The messages behind one sender's proposal, and what a chosen cleanup would do to each.
///
/// A proposal says "likely promotional clutter, 43 messages"; a preview says "38 would be
/// archived, 5 held back". Neither is checkable. This screen is where a user can actually look
/// at the 43, see the 5 and why they were spared, and decide whether the rules read their mail
/// the way they would have.
///
/// This screen is also the **only** place in the app that can change a mailbox, and it is
/// deliberately the one that already makes the user look at individual messages. Ticking rows
/// and pressing **Archive…** opens a confirmation; nothing else does. A proposal, a dry-run
/// preview, a saved plan, and a sender row can all lead the user *here*, and every one of them
/// stops at this boundary: there is no control anywhere that archives a sender or carries out a
/// plan.
///
/// ### How the preview and the selection are connected, and how they are not
///
/// **Fill from preview** exists because "38 messages would be affected" is only useful if the
/// user can get at those 38. It writes them into the checkbox column and does nothing else: no
/// request, no confirmation, no countdown. The user then reads the list, unticks what they want
/// to keep, ticks anything the rules missed, and takes it to a confirmation themselves. It never
/// fills in a protected message; see
/// ``InboxSessionModel/preselectableMessageIDs(forSenderKey:under:)``. The user is free to tick
/// one, and the confirmation says so plainly when they have.
///
/// The preview itself remains inert. There is no Execute, no Apply, and no sender-level archive.
///
/// Everything else here still changes nothing. There is no message body to show, because
/// ``MailMessage`` has nowhere to hold one, and the plan picker only changes which rows are
/// highlighted.
struct SenderMessageReviewView: View {

    let session: InboxSessionModel
    let summary: SenderSummary
    let proposal: SenderCleanupProposal?

    /// The preview-derived candidates a sender-level entry point asked to start from, or `nil`
    /// when the review was opened to look rather than to clean.
    ///
    /// Applied **once**, when the screen appears: it chooses the action shown in the picker and
    /// ticks the candidate rows. From that moment it is inert: it is not consulted again, it does
    /// not re-apply when the window reloads, and nothing on this screen syncs back to it. What the
    /// user does with those ticks is what the confirmation gets.
    var preselection: SenderReviewCandidates?

    @Environment(\.dismiss) private var dismiss

    @State private var sortOrder: MessageReviewSortOrder = .newestFirst
    @State private var action: PlannedCleanupAction?
    @State private var showsOnlyAffected = false

    /// The rows the user has ticked.
    ///
    /// Owned by the view rather than the session on purpose. A selection is a thought in
    /// progress, not app state: it performs no write, survives nothing, and the session never
    /// learns about it until the user asks for a confirmation. That is what makes "selection
    /// alone performs zero writes" true by construction rather than by discipline.
    ///
    /// Scoped to this sender by construction too, every identifier in here came from this
    /// screen's own rows, and re-checked against the sender when a set is frozen, so nothing
    /// left over from a re-sort or a reload can smuggle another sender's mail into a set.
    @State private var selectedMessageIDs: Set<MailMessage.ID> = []

    /// The frozen set a confirmation is open for.
    ///
    /// Separate from ``selectedMessageIDs`` so that ticking rows never, by itself, puts the app
    /// one keystroke away from a mutation. Pressing the button is what fills this in, and what
    /// goes in is a copy that the table underneath can no longer change.
    @State private var pendingArchive: ArchiveSelectionSnapshot?

    /// Said when a frozen set could not be built because the window moved under the selection.
    @State private var selectionIsStale = false

    /// The rule review, when the user has opened it.
    ///
    /// A sheet rather than a section, for the same reason the unsubscribe options are one: it is
    /// a different decision about different mail. This screen is about the messages already here;
    /// a rule is about the ones that have not arrived. Opening it creates nothing.
    @State private var isShowingRuleReview = false

    /// The unsubscribe options screen, when the user has opened it.
    ///
    /// A separate sheet rather than a section of this one, because the two answer different
    /// questions about different mail: this screen is about the messages already here, and that
    /// one is about the ones that have not arrived. Presenting it from here is a convenience,
    /// since the user is looking at this sender, not a suggestion that unsubscribing is part of
    /// the
    /// archive flow.
    @State private var isShowingUnsubscribeOptions = false

    /// The preselection that was actually applied, kept so the banner can say what it did.
    ///
    /// A record of something that already happened rather than live state. The user is free to
    /// untick every row it filled in, and the banner keeps saying what the preview picked, which
    /// is the honest thing for it to say, because "18 selected from this preview" is a fact about
    /// how the screen opened, not a claim about what is ticked now. The live count sits beside it
    /// in the selection row.
    @State private var appliedPreselection: SenderReviewCandidates?

    var body: some View {
        VStack(spacing: 0) {
            header
            preselectionNotice
            Divider()
            controls
            selectionControls
            Divider()
            messageTable
            Divider()
            footer
        }
        // The sheet takes its minimum width, so that is what has to fit all five columns: an
        // audit screen whose "under this plan" column is off the right edge audits nothing.
        .frame(minWidth: 900, idealWidth: 980, minHeight: 480, idealHeight: 620)
        .sheet(item: $pendingArchive) { frozen in
            ArchiveSelectionSheet(session: session, selection: frozen)
        }
        .sheet(isPresented: $isShowingUnsubscribeOptions) {
            UnsubscribeOptionsSheet(session: session, summary: summary)
        }
        .sheet(isPresented: $isShowingRuleReview) {
            // Derived here and handed over. `makeSenderRuleReview` reads the loaded window and
            // returns a value; it writes nothing, and the sheet's own confirming button is the
            // only thing in the app that creates a rule.
            if let review = session.makeSenderRuleReview(forSenderKey: summary.id) {
                SenderRuleReviewSheet(session: session, review: review)
            } else {
                RuleUnavailableSheet(session: session, summary: summary)
            }
        }
        .onAppear(perform: applyPreselectionIfNeeded)
    }

    // MARK: - Opening state

    /// Chooses the action and, when a sender-level entry point asked for one, the starting ticks.
    ///
    /// **This is the whole of what a sender-level action does.** It writes into two pieces of view
    /// state (which action the picker shows, and which checkboxes are on) and stops. No request
    /// is made, no confirmation opens, nothing is frozen, and nothing is scheduled. The screen the
    /// user lands on is the same screen they would have reached by opening the review and ticking
    /// the rows themselves; the only difference is that the ticking has been done for them, and
    /// they can undo every bit of it before anything is confirmed.
    private func applyPreselectionIfNeeded() {
        guard appliedPreselection == nil else { return }

        guard let preselection else {
            // Seeded from the proposal so the screen opens on the plan the app actually
            // suggested, rather than on whichever action happens to be first in a menu.
            if action == nil { action = proposal?.kind.defaultPlannedAction }
            return
        }

        action = preselection.action
        selectedMessageIDs = Set(preselection.messageIDs)
        appliedPreselection = preselection
    }

    // MARK: - Derived state

    /// Recomputed on every render from the session's in-memory window.
    ///
    /// Cheap (it is filtering and sorting messages already loaded) and recomputing is what
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
    /// Conditional because the old sentence, "no message is opened, moved, or changed",
    /// stopped being true on this exact screen the moment archiving arrived. It is still true
    /// where the app genuinely cannot write, and saying so there is worth doing; saying it
    /// beside a working Archive button would be worse than saying nothing.
    private var disclaimer: String {
        let preamble = "These are the \(reviewed.count) messages InboxSweep has loaded from this sender."
        guard session.canOfferArchiving else {
            return "\(preamble) Nothing on this screen is sent to Gmail, and no message is opened, moved, or changed."
        }
        return """
            \(preamble) No message is opened: there is no message body to show. The only thing \
            that changes your mailbox is Archive, which acts on exactly the messages you tick and \
            then confirm as a list, and can be undone.
            """
    }

    /// The ticked rows that are still in the window, in the order the table lists them.
    ///
    /// Recomputed from ``reviewed`` rather than trusted, so a selection that outlived a reload
    /// shrinks visibly instead of silently naming messages that are no longer there.
    private var selectedRows: [ReviewedMessage] {
        reviewed.filter { selectedMessageIDs.contains($0.id) }
    }

    private var selectedCount: Int { selectedRows.count }

    private var selectedProtectedCount: Int { selectedRows.count(where: \.isProtected) }

    /// The eligible rows a **Select all** would tick: everything currently visible.
    ///
    /// Visible rather than loaded, because "all" has to mean what is on screen. With the
    /// **Only affected** filter on, that is the affected rows; with it off, it is every loaded
    /// message from this sender.
    private var selectableVisibleIDs: [MailMessage.ID] { visible.map(\.id) }

    /// The rows the preview would reach, minus anything protected.
    ///
    /// Asked of the session rather than computed here, so the one rule that matters (a
    /// convenience action never picks a protected message) lives beside the archive path it
    /// protects rather than in a view.
    private var preselectableIDs: [MailMessageID] {
        guard let action else { return [] }
        return session.preselectableMessageIDs(forSenderKey: summary.id, under: action)
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

    /// What a sender-level entry point started this review with, and why.
    ///
    /// Shown whenever the screen was opened from one, including (especially) when it filled in
    /// nothing. A review that opened with no ticks and no sentence would read as a failure, and
    /// the thing it must never read as is an invitation to select everything instead. So the empty
    /// case names its reason and offers nothing: the ordinary controls below are still there, and
    /// the app does not manufacture a fallback selection to have something to show.
    @ViewBuilder
    private var preselectionNotice: some View {
        if let applied = appliedPreselection {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(applied.isEmpty ? "Nothing was preselected" : "\(applied.count) preselected for you")
                        .font(.callout.weight(.medium))
                        .accessibilityIdentifier("messageReview.preselectionHeadline")

                    Text(applied.emptyExplanation ?? applied.preselectionSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("messageReview.preselectionSummary")
                }
            } icon: {
                Image(systemName: applied.isEmpty ? "checkmark.shield" : "checklist")
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
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

            ruleControl
            unsubscribeControl
            archiveControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The way from this sender's messages to a rule about this sender's future messages.
    ///
    /// **Create archive rule…**, with the ellipsis carrying its usual meaning: it opens something
    /// to read, and nothing has happened when it is closed. Pressing it derives a review and
    /// presents it. It does not create a rule, does not enable one, and does not archive anything,
    /// and there is no path from this button to the rule store that skips the review's own
    /// confirming press.
    ///
    /// Offered whether or not this session can execute a rule, for the same reason the archive
    /// review and the unsubscribe options are: what it opens is a reading, and the review screen
    /// is the honest place to say whether anything can run. It is replaced by a way into Rules
    /// once this sender already has one, because the answer to "I want a rule for this sender" when
    /// there is one is to show it, not to stack a second.
    @ViewBuilder
    private var ruleControl: some View {
        if let existing = session.rule(forSenderKey: summary.id) {
            Button {
                isShowingRuleReview = true
            } label: {
                Label(existing.isEnabled ? "Rule is on" : "Rule is off", systemImage: "wand.and.stars.inverse")
            }
            .help("You already have a rule for this sender. Opens Rules, where you can turn it off or delete it.")
            .accessibilityIdentifier("messageReview.existingRuleButton")
        } else {
            Button {
                isShowingRuleReview = true
            } label: {
                Label("Create archive rule…", systemImage: "wand.and.stars.inverse")
            }
            .help("Shows exactly what a rule for this sender would do to future mail. Opening it creates nothing, and archives nothing.")
            .accessibilityIdentifier("messageReview.createRuleButton")
        }
    }

    /// The way from this sender's messages to this sender's unsubscribe options.
    ///
    /// **Unsubscribe…**, never *Stop all mail* or *Clean sender*. It is shown only when this
    /// sender's own headers actually said something: a sender with no metadata gets no control
    /// rather than a disabled one, because there is nothing behind it to enable.
    ///
    /// Pressing it opens a reading. Nothing is sent, nothing is opened, and the confirmation is
    /// two screens and two deliberate presses away.
    @ViewBuilder
    private var unsubscribeControl: some View {
        if unsubscribeOpportunity.availability.camesFromListHeader {
            Button {
                isShowingUnsubscribeOptions = true
            } label: {
                Label("Unsubscribe…", systemImage: "envelope.badge.shield.half.filled")
            }
            .disabled(session.isUnsubscribing)
            .help("Shows what this sender's headers say about unsubscribing, and where it would go. Opening it sends nothing. Unlike archiving, unsubscribing is about mail you haven't received yet.")
            .accessibilityIdentifier("messageReview.unsubscribeButton")
        }
    }

    /// What this sender's headers say about unsubscribing, read from the window in memory.
    private var unsubscribeOpportunity: UnsubscribeOpportunity {
        session.unsubscribeOpportunity(forSenderKey: summary.id)
    }

    /// The selection row: what is ticked, and the three ways to change it in bulk.
    ///
    /// Every control here writes to a `Set` of identifiers and nothing else. None of them
    /// contacts a provider, opens a confirmation, or starts a countdown, which is why they can
    /// be offered freely even though one of them is driven by a cleanup recommendation.
    @ViewBuilder
    private var selectionControls: some View {
        if session.canOfferArchiving, session.archiveCapability.isGranted, !reviewed.isEmpty {
            HStack(spacing: 12) {
                Text(selectionSummary)
                    .font(.callout)
                    .foregroundStyle(selectedCount == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .monospacedDigit()
                    .accessibilityIdentifier("messageReview.selectionSummary")

                Button("Select all shown") {
                    selectedMessageIDs.formUnion(selectableVisibleIDs)
                }
                .disabled(selectableVisibleIDs.allSatisfy(selectedMessageIDs.contains))
                .help("Ticks every message currently listed. Nothing is archived until you confirm.")
                .accessibilityIdentifier("messageReview.selectAllButton")

                Button("Deselect all") {
                    selectedMessageIDs.removeAll()
                }
                .disabled(selectedMessageIDs.isEmpty)
                .accessibilityIdentifier("messageReview.deselectAllButton")

                if action != nil {
                    Button("Fill from preview") {
                        // Writes identifiers into the checkbox column. That is the whole of it:
                        // the user still has to read the list, edit it, open a confirmation, and
                        // press a button. The preview cannot execute, and this does not make it
                        // executable: it makes its result editable.
                        selectedMessageIDs.formUnion(preselectableIDs)
                    }
                    .disabled(preselectableIDs.isEmpty || preselectableIDs.allSatisfy(selectedMessageIDs.contains))
                    .help("Ticks the messages this preview would affect so you can check and edit them. It archives nothing, and never ticks a protected message.")
                    .accessibilityIdentifier("messageReview.fillFromPreviewButton")
                }

                Spacer()

                if selectedProtectedCount > 0 {
                    Label(
                        selectedProtectedCount == 1
                            ? "1 protected message selected"
                            : "\(selectedProtectedCount) protected messages selected",
                        systemImage: "shield.lefthalf.filled"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("InboxSweep never picks these for you. You can archive them anyway, and the confirmation will say so.")
                    .accessibilityIdentifier("messageReview.protectedSelectionWarning")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var selectionSummary: String {
        switch selectedCount {
        case 0: "No messages selected"
        case 1: "1 of \(reviewed.count) selected"
        default: "\(selectedCount) of \(reviewed.count) selected"
        }
    }

    /// The app's only route to changing a mailbox.
    ///
    /// Shown at all only when the provider can write: the synthetic mailbox gets nothing, not
    /// a disabled button promising something it could never do. When the provider can write but
    /// the grant does not cover it, the control becomes the request for that permission, which
    /// keeps consenting and archiving two separate presses.
    @ViewBuilder
    private var archiveControl: some View {
        if session.canOfferArchiving {
            if session.archiveCapability.isGranted {
                Button {
                    // Read from the table's own ticked rows, not from a proposal, a plan, or a
                    // recommendation. This is the only thing in the app that opens a
                    // confirmation, and only a person pressing this button performs it.
                    //
                    // The set is *frozen* here rather than passed live: from this line onwards
                    // the confirmation describes a fixed list, and the session refuses it if the
                    // window stops agreeing rather than acting on whatever is selected by then.
                    let frozen = session.makeArchiveSelection(
                        forSenderKey: summary.id,
                        messageIDs: selectedMessageIDs,
                        // Where the ticks came from, recorded on the transaction so Activity can
                        // tell the two apart later. It changes nothing about what is archived:
                        // both are this screen's own checkbox column, and both go through the
                        // same confirmation.
                        origin: appliedPreselection == nil ? .confirmed : .senderReviewed
                    )
                    if let frozen {
                        selectionIsStale = false
                        pendingArchive = frozen
                    } else {
                        // Refused rather than narrowed. A confirmation for "the ones that are
                        // still there" would be a confirmation of a set nobody approved.
                        selectionIsStale = true
                    }
                } label: {
                    Label(archiveButtonTitle, systemImage: "archivebox")
                }
                .disabled(selectedCount == 0 || session.isMutating)
                .help(
                    selectedCount == 0
                        ? "Tick the messages you want archived. Archiving removes them from your Inbox; it does not delete them."
                        : "Asks you to confirm the exact list, then removes those messages from your Inbox. They are not deleted, and you can undo it."
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

    private var archiveButtonTitle: String {
        switch selectedCount {
        case 0: "Archive…"
        case 1: "Archive 1 message…"
        default: "Archive \(selectedCount) messages…"
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
            Table(visible, selection: $selectedMessageIDs) {
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
                        Text("None").foregroundStyle(.tertiary)
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
            if selectionIsStale {
                Label(
                    "The mailbox changed since you ticked those messages, so InboxSweep didn't open a confirmation. Reload and choose again.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("messageReview.staleSelectionNotice")
            }

            undoOffer

            if unsubscribeOpportunity.availability.camesFromListHeader {
                // Said on the screen that offers both, because this is where somebody could
                // most easily take one for the other.
                Label(UnsubscribeOpportunity.futureMailNote, systemImage: "calendar.badge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("messageReview.unsubscribeDistinctionNote")
            }

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
                        // archives the ticked messages. Leaving the difference implicit would be
                        // the easiest way for someone to believe the preview was about to run.
                        Text("Archiving the messages you tick is the only change InboxSweep can make to this mailbox, and it asks first. The preview above is not something it can carry out: Fill from preview only ticks boxes for you to check.")
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

    /// The standing offer to put back the last archive, wherever it came from.
    ///
    /// Shown here (on the screen the user is most likely to be looking at) because the offer
    /// now outlives the sheet that created it and a relaunch of the app. An offer that existed
    /// only inside a dismissed sheet would be an offer nobody could find.
    ///
    /// It names a count and never re-derives a set: the messages it restores are the ones the
    /// stored transaction confirmed, and nothing on this screen can widen that.
    @ViewBuilder
    private var undoOffer: some View {
        if let undoable = session.undoableArchive, undoable.isUndoable, session.mutationActivity == nil {
            HStack(spacing: 10) {
                Label {
                    Text(
                        undoable.succeededCount == 1
                            ? "1 message was archived. You can still put it back."
                            : "\(undoable.succeededCount) messages were archived. You can still put them back."
                    )
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }

                Button("Undo") { session.undoLastArchive() }
                    .disabled(session.isMutating)
                    .help("Sends a real request to Gmail putting those messages back in your Inbox.")
                    .accessibilityIdentifier("messageReview.undoButton")

                Spacer()
            }
            .accessibilityIdentifier("messageReview.undoOffer")
        }
    }

    /// A couple of words for a narrow column; the full sentence is the tooltip.
    private func protectionSummary(_ reason: CleanupExclusionReason) -> String {
        switch reason {
        case .starred: "Starred"
        case .markedImportant: "Important"
        case .protectedTopic(let topic): topic.displayName
        case .replyLikeSubject: "Conversation"
        case .newerThanCutoff, .amongNewestKept, .actionMovesNoMessages: "None"
        }
    }
}

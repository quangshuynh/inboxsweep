import SwiftUI

/// What InboxSweep has changed in this mailbox, newest first — and nothing else.
///
/// ### The one question this screen answers
///
/// "What has InboxSweep done to my mail?" Not "what happened in Gmail": a message archived in
/// the Gmail web app, on a phone, or by somebody's own filter never appears here. The app
/// reconciles the mailbox it can see on a reload, and it does not write a transaction for work
/// it did not do. A screen that blurred the two would be a worse answer than no screen.
///
/// ### It is a reader
///
/// Opening it, scrolling it, and opening a row send nothing to Gmail and nothing to anybody
/// else. The history comes out of the local transaction file and the message details out of the
/// window already in memory. The only control here that can reach a mailbox is **Undo**, which
/// is the existing undo — the same offer the review screen makes, for the same single
/// transaction, through the same path. A row cannot archive anything, an older row cannot become
/// undoable by being visible, and **no unsubscribe row has any control on it at all**: there is
/// no re-send, no retry, and no undo, because an unsubscribe has no inverse to offer.
///
/// ### Two kinds of row
///
/// Archives and unsubscribes are interleaved by time and rendered differently, because they say
/// different things. An archive row counts messages and says where its undo stands; an
/// unsubscribe row names a destination and says what InboxSweep did — "Unsubscribe request
/// sent", "Opened unsubscribe page", "Opened email unsubscribe request". None of the three
/// claims the user was unsubscribed, which is not something this app can observe.
///
/// ### Tone
///
/// Counts and dates, no congratulation. Archiving is not deleting, InboxSweep's proposals are
/// guesses, and "12 useless emails removed!" would be wrong on both counts.
struct ActivityView: View {

    let session: InboxSessionModel

    @Environment(\.dismiss) private var dismiss

    /// Loaded when the screen opens and after an undo, from the local file.
    @State private var entries: [ActivityTimelineEntry] = []
    @State private var selectedEntryID: ActivityTimelineEntry.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 460, idealHeight: 580)
        .task(id: session.mutationActivity?.id) { await reload() }
        // A second trigger for the second kind of entry, so an unsubscribe performed while this
        // screen is open shows up the way an undo does.
        .task(id: session.unsubscribeActivity?.id) { await reload() }
    }

    // MARK: - Derived state

    private var selectedEntry: ActivityTimelineEntry? {
        entries.first { $0.id == selectedEntryID }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The identifier sits on the title rather than on the stack: SwiftUI pushes an
            // identifier down onto descendants and would take the scope note with it.
            Text("Activity")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("activity.screen")

            Label {
                Text(Self.scopeNote)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("activity.scopeNote")
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    /// The boundary, stated on the screen rather than left to documentation.
    static let scopeNote = """
        Everything InboxSweep has done for this account, on this Mac — messages it archived, and \
        unsubscribes it sent or opened for you. Changes you made in Gmail itself are not listed \
        here, and neither is an unsubscribe you did yourself: InboxSweep only records what it did.
        """

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            emptyState
        } else {
            HSplitView {
                entryList
                detail
            }
        }
    }

    /// Nothing archived yet — which is a perfectly good state and is not apologised for.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No activity yet", systemImage: "clock")
        } description: {
            Text("""
                InboxSweep hasn't done anything to this account yet. When you archive messages, each \
                archive is listed here with what it did and whether it can still be undone — and when \
                you unsubscribe from a sender, what InboxSweep sent or opened is listed too.
                """)
        }
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("activity.empty")
    }

    private var entryList: some View {
        List(entries, selection: $selectedEntryID) { entry in
            Group {
                switch entry {
                case .archive(let archive): ActivityRow(entry: archive)
                case .unsubscribe(let unsubscribe): UnsubscribeActivityRow(entry: unsubscribe)
                }
            }
            .tag(entry.id)
        }
        .listStyle(.inset)
        .frame(minWidth: 320, idealWidth: 380)
        .accessibilityIdentifier("activity.list")
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedEntry {
            Group {
                switch selectedEntry {
                case .archive(let archive):
                    ActivityDetailView(entry: archive, session: session)
                case .unsubscribe(let unsubscribe):
                    UnsubscribeActivityDetailView(entry: unsubscribe)
                }
            }
            .frame(minWidth: 320)
        } else {
            ContentUnavailableView(
                "No change selected",
                systemImage: "list.bullet.rectangle",
                description: Text("Select a change to see exactly what it did.")
            )
            .frame(minWidth: 320, maxHeight: .infinity)
            .accessibilityIdentifier("activity.noSelection")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(Self.retentionNote)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("activity.retentionNote")

            Spacer(minLength: 12)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("activity.doneButton")
        }
        .padding(16)
    }

    /// Says the history is bounded, before somebody notices an old change has gone and assumes
    /// something went wrong.
    static let retentionNote = """
        InboxSweep keeps the \(MailMutationHistory.entryLimit) most recent archives and the \
        \(MailMutationHistory.unsubscribeEntryLimit) most recent unsubscribes for this account on \
        this Mac, and no message content. Signing out deletes them.
        """

    // MARK: - Loading

    /// Reads the history for the connected account.
    ///
    /// Re-run when a mutation finishes — which on this screen means an undo — so the row the
    /// user just acted on updates in place rather than going stale behind them.
    private func reload() async {
        entries = await session.activityTimeline()

        // A selection that survived a reload but no longer names a row would leave the detail
        // pane empty with no way back to it.
        if let selectedEntryID, !entries.contains(where: { $0.id == selectedEntryID }) {
            self.selectedEntryID = nil
        }
    }
}

/// One change, as a row: what it did, when, and where its undo stands.
private struct ActivityRow: View {

    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)

                Text(entry.occurredAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let unchanged = entry.unchangedSummary {
                    Text(unchanged)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let attribution = entry.ruleAttribution {
                    Text(attribution)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("activity.row.ruleAttribution")
                }

                if let status = entry.statusSummary {
                    Label(status, systemImage: statusSymbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("activity.row")
    }

    private var symbolName: String {
        switch entry.operation {
        case .archive: entry.confirmedCount == 0 ? "exclamationmark.triangle" : "archivebox"
        case .restoreToInbox: "arrow.uturn.backward"
        }
    }

    private var statusSymbolName: String {
        switch entry.status {
        case .undoAvailable: "arrow.uturn.backward.circle"
        case .undoSuperseded: "clock.badge.xmark"
        case .undoCompleted: "checkmark.circle"
        case .undoPartiallyCompleted: "circle.lefthalf.filled"
        case .restore: "tray.and.arrow.down"
        case .nothingChanged: "minus.circle"
        }
    }
}

/// One change in full: the counts, the state of its undo, and what it means.
private struct ActivityDetailView: View {

    let entry: ActivityEntry
    let session: InboxSessionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading
                tallies
                explanation
                messages
                undoSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .accessibilityIdentifier("activity.detail")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("activity.detail.title")

            Text(entry.occurredAt.formatted(.dateTime.weekday(.wide).day().month().year().hour().minute()))
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("activity.detail.timestamp")
        }
    }

    /// The counts, side by side.
    ///
    /// Three numbers rather than a verdict, for the same reason the confirmation sheet shows
    /// three: a set operation does not have a verdict, and "10 selected, 8 archived, 2 unchanged"
    /// is the sentence somebody can actually check against their mailbox.
    private var tallies: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 22) {
                tally("Selected", entry.selectedCount)
                tally(entry.operation == .archive ? "Archived" : "Put back", entry.confirmedCount)
                if entry.unchangedCount > 0 {
                    tally("Unchanged", entry.unchangedCount)
                }
                if entry.restoredCount > 0 {
                    tally("Since put back", entry.restoredCount)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
        }
        .accessibilityIdentifier("activity.detail.tallies")
    }

    private func tally(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("activity.detail.explanation")

            if let attribution = entry.ruleAttribution {
                Label(attribution, systemImage: "wand.and.stars.inverse")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("activity.detail.ruleAttribution")
            }

            if let status = entry.statusSummary {
                Label(status, systemImage: "info.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("activity.detail.status")
            }
        }
    }

    /// The messages, when the loaded window still describes them.
    ///
    /// Best-effort by design. The transaction names identifiers and the mailbox cache holds the
    /// metadata; when the two no longer overlap the counts above are still the whole truth, and
    /// this section says why the subjects are missing rather than pretending they never existed.
    @ViewBuilder
    private var messages: some View {
        if entry.hasResolvedMetadata || entry.metadataFallback != nil {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if entry.hasResolvedMetadata {
                        ForEach(entry.resolvedMessages) { message in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(message.subject ?? "No subject")
                                    .font(.callout)
                                    .foregroundStyle(message.subject == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(message.receivedAt.formatted(.dateTime.day().month().year().hour().minute()))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let fallback = entry.metadataFallback {
                        Text(fallback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("activity.detail.metadataFallback")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .accessibilityIdentifier("activity.detail.messages")
        }
    }

    /// The existing undo, offered here only when it is already the one on offer.
    ///
    /// ``InboxSessionModel/canUndo(_:)`` is the whole of the decision, and it compares against the
    /// session's single undo offer. Nothing on this screen widens it, reconstructs a set from
    /// what is displayed, or makes a superseded change actionable again.
    @ViewBuilder
    private var undoSection: some View {
        if entry.isUndoable {
            VStack(alignment: .leading, spacing: 8) {
                Text("""
                    Undo puts \(entry.transaction.succeededCount == 1 ? "this message" : "these \(entry.transaction.succeededCount) messages") \
                    back in your Inbox. It's a real request to Gmail, not a correction on this Mac.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    session.undoLastArchive()
                } label: {
                    Label("Undo this archive", systemImage: "arrow.uturn.backward")
                }
                .disabled(session.isMutating)
                .accessibilityIdentifier("activity.undoButton")
            }
        }
    }
}

// Previews are development-only, and these run on the debug-only sample mailbox, so the whole
// block stays out of release builds.
#if DEBUG
#Preview("Populated") {
    ActivityPreview(seedsHistory: true)
}

#Preview("Empty") {
    ActivityPreview(seedsHistory: false)
}

/// Drives the Activity preview from the synthetic mailbox.
///
/// The populated variant seeds the transaction store directly rather than archiving anything:
/// ``SampleMailProvider`` vends no mutation boundary, so there is nothing in a sample run that
/// could produce a transaction — which is the point, and also why the states this screen has to
/// get right are otherwise only visible on a real account.
///
/// It covers the four that read differently: a complete archive with its undo still open, a
/// partial archive, one that has been partly undone, and a restore.
private struct ActivityPreview: View {

    let seedsHistory: Bool

    @State private var session: InboxSessionModel
    @State private var isReady = false

    init(seedsHistory: Bool) {
        self.seedsHistory = seedsHistory
        _session = State(initialValue: InboxSessionModel(
            provider: SampleMailProvider(),
            mutationRecords: EphemeralMutationRecordStore(),
            fetchRequest: MailFetchRequest(limit: 60)
        ))
    }

    var body: some View {
        Group {
            if isReady {
                ActivityView(session: session)
            } else {
                ProgressView()
            }
        }
        .frame(width: 940, height: 620)
        .task {
            let records = EphemeralMutationRecordStore()
            if seedsHistory {
                for transaction in Self.sampleHistory { _ = await records.record(transaction) }
            }
            session = InboxSessionModel(
                provider: SampleMailProvider(),
                mutationRecords: records,
                fetchRequest: MailFetchRequest(limit: 60)
            )
            await session.connect().value
            isReady = true
        }
    }

    private static var sampleHistory: [MailMutationTransaction] {
        let account = SampleMailbox.account.emailAddress.address
        let now = Date()

        func transaction(
            _ operation: MailMutationOperation,
            ids: [String],
            selected: Int,
            confirmed: Int,
            minutesAgo: Double,
            undoState: MailMutationTransaction.UndoState
        ) -> MailMutationTransaction {
            MailMutationTransaction(
                id: UUID(),
                operation: operation,
                accountAddress: account,
                succeededMessageIDs: ids.map { MailMessageID($0) },
                selectedMessageCount: selected,
                occurredAt: now.addingTimeInterval(-60 * minutesAgo),
                undoState: undoState,
                confirmedMessageCount: confirmed
            )
        }

        // The sample mailbox's own identifiers, so the detail view has metadata to resolve for
        // the newest entry and nothing to resolve for the older ones — which is the graceful
        // degradation this screen has to show.
        let loaded = SampleMailbox.messages().prefix(3).map(\.id.rawValue)

        return [
            transaction(.archive, ids: Array(loaded), selected: 3, confirmed: 3,
                        minutesAgo: 12, undoState: .undoable),
            transaction(.archive, ids: ["gone-1", "gone-2", "gone-3", "gone-4", "gone-5", "gone-6"],
                        selected: 8, confirmed: 6, minutesAgo: 90, undoState: .superseded),
            transaction(.archive, ids: ["half-1", "half-2"],
                        selected: 5, confirmed: 5, minutesAgo: 1_500, undoState: .superseded),
            transaction(.restoreToInbox, ids: ["back-1", "back-2", "back-3"],
                        selected: 3, confirmed: 3, minutesAgo: 1_480, undoState: .notUndoable),
        ]
    }
}
#endif

/// One unsubscribe, as a row: what InboxSweep did, where, and when.
///
/// Notice what it does not carry. There is no count, because an unsubscribe is not about a
/// number of messages. There is no undo state, because there is no undo. And there is no
/// control of any kind — a row on this screen cannot re-send anything, which is what makes
/// scrolling past it free.
private struct UnsubscribeActivityRow: View {

    let entry: UnsubscribeActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: entry.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)

                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(entry.occurredAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let status = entry.statusSummary {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("activity.unsubscribeRow")
    }
}

/// One unsubscribe in full.
///
/// It takes no `session`, unlike its archive counterpart, and the absence is the point: there
/// is nothing on this screen for a session to do. An archive detail view holds an Undo button
/// and therefore needs the object that can perform one. This view is text.
private struct UnsubscribeActivityDetailView: View {

    let entry: UnsubscribeActivityEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading
                facts
                explanation
                noUndo
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .accessibilityIdentifier("activity.unsubscribeDetail")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("activity.unsubscribeDetail.title")

            Text(entry.occurredAt.formatted(.dateTime.weekday(.wide).day().month().year().hour().minute()))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// What was recorded, which is deliberately little.
    private var facts: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Mechanism") { Text(entry.mechanism.displayName) }
                LabeledContent(entry.mechanism == .mail ? "Mail domain" : "Host") {
                    Text(entry.destinationHost)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("activity.unsubscribeDetail.host")
                }
                if let status = entry.statusCode {
                    LabeledContent("Answer") { Text("HTTP \(status)") }
                }
                if let sender = entry.resolvedSender {
                    LabeledContent("Sender") {
                        Text(sender.displayValue)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .font(.callout)
            .padding(6)
        }
        .accessibilityIdentifier("activity.unsubscribeDetail.facts")
    }

    private var explanation: some View {
        Text(entry.explanation)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("activity.unsubscribeDetail.explanation")
    }

    /// Why there is no button here.
    private var noUndo: some View {
        Label {
            Text(UnsubscribeActivityEntry.noUndoNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "arrow.uturn.backward.slash")
        }
        .accessibilityIdentifier("activity.unsubscribeDetail.noUndo")
    }
}

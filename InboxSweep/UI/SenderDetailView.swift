import SwiftUI

/// The inspector shown for a selected sender.
///
/// Answers the two questions an aggregate row raises: "what does InboxSweep make of this?" and
/// "which messages are these?". The proposal and its full reasoning come first, then the
/// counts and observations behind them, then the messages themselves. It offers no action of
/// its own: **Review…** opens the screen where a single message can be archived, and this
/// inspector stays a view of a sender rather than a place a sender can be acted on.
struct SenderDetailView: View {

    let summary: SenderSummary

    /// The proposal for this sender, when one has been computed.
    ///
    /// Passed in rather than derived, for the same reason `messages` is: proposals belong to
    /// the loaded window the session owns, and a view that computed its own could show
    /// reasoning that disagreed with the dashboard row the user clicked.
    let proposal: SenderCleanupProposal?

    /// The loaded messages from this sender, newest first.
    ///
    /// Passed in rather than derived here: the window lives in the session, and a view that
    /// went looking for it would be the first place in the app where a screen owned mail.
    let messages: [MailMessage]

    /// Opens the full message review for this sender.
    ///
    /// The inspector lists the messages; the review screen is where they can be sorted and
    /// checked against a planned action. Kept as a callback rather than a sheet presented from
    /// here, so the inspector stays a view of a sender rather than an owner of navigation.
    var onReviewMessages: (() -> Void)?

    /// Opens the same review, starting from what this sender's current preview would reach.
    ///
    /// The sender-level convenience, and the wording is the design. **Review messages to
    /// archive…** says what pressing it does: it opens a review with boxes already ticked. It is
    /// not *Archive sender*, *Clean sender*, or *Apply recommendation*, because none of those is
    /// something InboxSweep can do — there is no whole-sender operation behind this, and the
    /// button itself changes nothing at all.
    ///
    /// Optional, and absent when there is no action to derive candidates from.
    var onReviewCleanup: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identity

                if let proposal {
                    Divider()
                    ProposalReasoningView(proposal: proposal)
                }

                Divider()
                counts
                Divider()
                dates
                Divider()
                observations

                if !messages.isEmpty {
                    Divider()
                    messageList
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .accessibilityIdentifier("senderDetail.screen")
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.sender.displayValue)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

            if let address = summary.sender.secondaryDisplayValue {
                Text(address)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !summary.sender.hasAddress {
                Text("These messages had a `From` header InboxSweep couldn't read, so they're grouped together.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var counts: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            row("Messages loaded", summary.messageCount)
            row("Unread", summary.unreadCount)
            row("Starred", summary.starredCount)
            row("Marked important", summary.importantCount)
        }
    }

    private func row(_ label: String, _ value: Int) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
        .font(.callout)
    }

    private var dates: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Last loaded message") {
                Text(summary.newestReceivedAt, format: .dateTime.day().month().year().hour().minute())
            }
            LabeledContent("First loaded message") {
                Text(summary.oldestLoadedReceivedAt, format: .dateTime.day().month().year().hour().minute())
            }
        }
        .font(.callout)
    }

    /// Facts about this sender's mail that came from the mailbox itself.
    ///
    /// The caption matters as much as the values: Gmail's categories are Gmail's, and a
    /// `List-Unsubscribe` header is a header that was present — neither is a verdict from
    /// InboxSweep about whether this sender is worth keeping.
    private var observations: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Observations")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                if !summary.orderedCategoryLabels.isEmpty {
                    LabeledContent("Gmail categories") {
                        Text(summary.orderedCategoryLabels.map(\.displayName).joined(separator: ", "))
                            .multilineTextAlignment(.trailing)
                    }
                }

                LabeledContent("List-Unsubscribe header") {
                    Text(unsubscribeDescription)
                        .multilineTextAlignment(.trailing)
                }

                if let cadence = cadenceDescription {
                    LabeledContent("Arrives") {
                        Text(cadence)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .font(.callout)

            Text("""
                Gmail applies its own categories; InboxSweep only reports which ones it saw. \
                Frequency is measured across the loaded messages, so loading more can change it. \
                InboxSweep never contacts an unsubscribe address.
                """)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("senderDetail.observations")
    }

    private var unsubscribeDescription: String {
        switch summary.listUnsubscribeCount {
        case 0: "On none of the loaded messages"
        case summary.messageCount: "On every loaded message"
        case let count: "On \(count) of \(summary.messageCount) loaded messages"
        }
    }

    /// Renders the mean gap between loaded messages as a phrase, or `nil` when there is no
    /// gap to measure.
    private var cadenceDescription: String? {
        guard let interval = summary.averageIntervalBetweenLoadedMessages else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute]
        guard let formatted = formatter.string(from: interval) else { return nil }
        // "About" because this is a mean over a window, not a schedule the sender keeps.
        return "about one message every \(formatted)"
    }

    /// The messages themselves — the direct answer to "which messages are these?".
    private var messageList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Loaded messages")
                    .font(.headline)
                Spacer()
                if let onReviewCleanup {
                    Button("Review messages to archive…", action: onReviewCleanup)
                        .buttonStyle(.link)
                        .help("Opens the message review with the messages this sender's preview would reach already ticked, so you can check them, change the list, and decide. Nothing is archived by opening it.")
                        .accessibilityIdentifier("senderDetail.reviewCleanupButton")
                }
                if let onReviewMessages {
                    Button("Review…", action: onReviewMessages)
                        .buttonStyle(.link)
                        .help("Sort these messages and see which a cleanup would reach. Nothing is changed.")
                        .accessibilityIdentifier("senderDetail.reviewButton")
                }
            }

            Text("^[\(messages.count) message](inflect: true) from this sender in the loaded window.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // The identifier sits on the list itself rather than on the section: SwiftUI
            // pushes an identifier down onto its descendants, so a section-wide one would
            // erase the Review button's and make it unfindable.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(messages) { message in
                    MessageRow(message: message)
                    if message.id != messages.last?.id {
                        Divider()
                    }
                }
            }
            .accessibilityIdentifier("senderDetail.messages")
        }
    }
}

/// One loaded message: its subject, when it arrived, and the states it is in.
///
/// Deliberately unopenable. There is no body to show and no action to take, so a row that
/// looked like a button would promise something the app cannot do.
private struct MessageRow: View {

    let message: MailMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(message.subject ?? "No subject")
                .font(.callout)
                .fontWeight(message.isUnread ? .semibold : .regular)
                .foregroundStyle(message.subject == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(message.receivedAt, format: .dateTime.day().month().year().hour().minute())
                    .foregroundStyle(.secondary)

                ForEach(states, id: \.self) { state in
                    Text(state)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    /// The message's states, in a fixed order so rows read consistently.
    private var states: [String] {
        var states: [String] = []
        if message.isUnread { states.append("Unread") }
        if message.isStarred { states.append("Starred") }
        if message.isImportant { states.append("Important") }
        states += message.labels.filter(\.isCategory)
            .map(\.displayName)
            .sorted()
        return states
    }
}

// Previews are development-only, and some of them run on the debug-only sample
// mailbox, so the whole block stays out of release builds.
#if DEBUG
#Preview {
    let messages = SampleMailbox.messages()
        .filter { $0.sender.address == "newsletter@example.com" }

    let summary = SenderAggregator.aggregate(messages)[0]

    return SenderDetailView(
        summary: summary,
        proposal: CleanupProposalEngine.evaluate(SenderEvidenceBuilder.build(summary: summary, messages: messages)),
        messages: messages.sorted { $0.receivedAt > $1.receivedAt }
    )
    .frame(width: 360, height: 760)
}
#endif

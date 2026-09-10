import SwiftUI

/// The inspector shown for a selected sender.
///
/// Exists because the aggregate row raises an obvious question — "which messages are these?"
/// — and this screen answers it directly: the counts, the observations behind them, and the
/// loaded messages themselves. Every line is something the mailbox already said. It offers no
/// action, in keeping with the app being read-only.
struct SenderDetailView: View {

    let summary: SenderSummary

    /// The loaded messages from this sender, newest first.
    ///
    /// Passed in rather than derived here: the window lives in the session, and a view that
    /// went looking for it would be the first place in the app where a screen owned mail.
    let messages: [MailMessage]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identity
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
            Text("Loaded messages")
                .font(.headline)

            Text("^[\(messages.count) message](inflect: true) from this sender in the loaded window.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(messages) { message in
                    MessageRow(message: message)
                    if message.id != messages.last?.id {
                        Divider()
                    }
                }
            }
        }
        .accessibilityIdentifier("senderDetail.messages")
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

    SenderDetailView(
        summary: SenderAggregator.aggregate(messages)[0],
        messages: messages.sorted { $0.receivedAt > $1.receivedAt }
    )
    .frame(width: 340, height: 620)
}
#endif

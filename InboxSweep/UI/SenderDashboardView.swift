import SwiftUI

/// The connected dashboard: who sent the loaded mail, and how much of it.
///
/// Every number on this screen describes the *loaded window*, not the whole mailbox, and the
/// header says so. There is no action here that touches mail — the only buttons load more of
/// it, re-read it, or disconnect the app.
struct SenderDashboardView: View {

    let snapshot: InboxSnapshot
    let session: InboxSessionModel

    @State private var selectedSenderID: SenderSummary.ID?
    @State private var isInspectorPresented = false

    var body: some View {
        VStack(spacing: 0) {
            AccountSummaryHeader(snapshot: snapshot)
            Divider()
            senderTable
            Divider()
            footer
        }
        .toolbar { toolbarContent }
        .inspector(isPresented: $isInspectorPresented) {
            Group {
                if let sender = selectedSender {
                    SenderDetailView(
                        summary: sender,
                        messages: session.loadedMessages(forSenderKey: sender.id)
                    )
                } else {
                    ContentUnavailableView("No sender selected", systemImage: "person.crop.circle")
                }
            }
            .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
        }
        .accessibilityIdentifier("dashboard.screen")
    }

    private var selectedSender: SenderSummary? {
        snapshot.senders.first { $0.id == selectedSenderID }
    }

    private var senderTable: some View {
        Table(snapshot.senders, selection: $selectedSenderID) {
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
            .width(min: 200, ideal: 300)

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

            TableColumn("Starred") { summary in
                Text(summary.starredCount, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(summary.starredCount > 0 ? .primary : .tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 70)

            TableColumn("Latest") { summary in
                Text(summary.newestReceivedAt, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 130)
        }
        .tableStyle(.inset)
        .accessibilityIdentifier("dashboard.senderTable")
        .onChange(of: selectedSenderID) { _, newValue in
            isInspectorPresented = newValue != nil
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if snapshot.hasMoreMessages {
                Button {
                    session.loadMore()
                } label: {
                    if snapshot.isLoadingMore {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading…")
                        }
                    } else {
                        Text("Load more messages")
                    }
                }
                .disabled(snapshot.isLoadingMore)
                .accessibilityIdentifier("dashboard.loadMoreButton")

                if snapshot.isLoadingMore {
                    Button("Cancel", role: .cancel) { session.cancel() }
                }
            } else {
                Text("All messages in the loaded window are shown.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(PrivacyNotice.summary)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .help("InboxSweep has no ability to delete, archive, or modify mail in this version.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        fetchRequest: MailFetchRequest(limit: 40)
    )

    var body: some View {
        Group {
            if let snapshot = session.state.snapshot {
                SenderDashboardView(snapshot: snapshot, session: session)
            } else {
                ProgressView()
            }
        }
        .frame(width: 980, height: 620)
        .task { await session.connect().value }
    }
}
#endif

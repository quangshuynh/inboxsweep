import SwiftUI

/// Shown when a load succeeds but finds no messages.
///
/// Distinct from the error screen on purpose: an empty inbox is a success, and telling
/// someone their empty inbox is a problem would be both wrong and mildly insulting.
struct InboxEmptyView: View {

    let snapshot: InboxSnapshot
    let session: InboxSessionModel

    @State private var isActivityPresented = false

    var body: some View {
        VStack(spacing: 20) {
            ContentUnavailableView {
                Label("Nothing to look at", systemImage: "tray")
            } description: {
                Text("""
                    InboxSweep didn't find any messages in the inbox for \
                    \(snapshot.account.emailAddress.displayValue).
                    """)
            } actions: {
                Button("Check again") { session.reload() }
                    .accessibilityIdentifier("empty.reloadButton")
            }

            HStack(spacing: 16) {
                // Reachable from here too, because an empty inbox is one of the states somebody
                // is most likely to be asking "what did this app do?" about — and the dashboard
                // that carries the usual Activity button is not on screen.
                Button("Activity") { isActivityPresented = true }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("empty.activityButton")

                Button("Disconnect") { session.disconnect() }
                    .buttonStyle(.link)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isActivityPresented) {
            ActivityView(session: session)
        }
        .accessibilityIdentifier("empty.screen")
    }
}

// Previews are development-only, and some of them run on the debug-only sample
// mailbox, so the whole block stays out of release builds.
#if DEBUG
#Preview {
    InboxEmptyView(
        snapshot: InboxSnapshot(
            account: MailAccount(
                emailAddress: EmailAddress(displayName: nil, address: "sample.user@example.com"),
                providerDisplayName: "Gmail"
            ),
            loadedMessageCount: 0,
            senders: [],
            sortOrder: .messageVolume,
            hasMoreMessages: false,
            isLoadingMore: false
        ),
        session: InboxSessionModel(provider: SampleMailProvider())
    )
    .frame(width: 720, height: 460)
}
#endif

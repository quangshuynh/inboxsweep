import SwiftUI

/// The controls that decide *how much mailbox the app has actually looked at*.
///
/// This bar exists because every proposal on the dashboard is computed from the loaded window
/// and nothing else. Before this interval the window was a constant the user could only extend
/// one page at a time, which made the single most important input to every suggestion the least
/// visible thing on screen.
///
/// Three things live here, in the order they matter: which scope is being read, how much has
/// been read, and how to read more.
struct MailboxLoadBar: View {

    let snapshot: InboxSnapshot
    let session: InboxSessionModel

    var body: some View {
        HStack(spacing: 12) {
            scopePicker
            Divider().frame(height: 18)
            coverage
            Spacer(minLength: 12)
            depthPicker
            loadControls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Scope

    private var scopePicker: some View {
        Picker("Read", selection: Binding(
            get: { session.scope },
            set: { session.scope = $0 }
        )) {
            ForEach(MailboxScope.offered) { scope in
                Text(scope.displayName).tag(scope)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(snapshot.isLoadingMore)
        .help(session.scope.coverageCaveat)
        .accessibilityIdentifier("dashboard.scopePicker")
    }

    // MARK: - Coverage

    /// How much mail has been analysed — stated, never implied.
    private var coverage: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(snapshot.loadProgressDescription ?? snapshot.coverageHeadline)
                .font(.callout)
                .monospacedDigit()
                .accessibilityIdentifier("dashboard.coverageHeadline")

            Text(snapshot.coverageDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(snapshot.coverageDetail)
                .accessibilityIdentifier("dashboard.coverageDetail")
        }
    }

    // MARK: - Depth

    private var depthPicker: some View {
        Picker("Load", selection: Binding(
            get: { session.loadDepth },
            set: { session.loadDepth = $0 }
        )) {
            ForEach(MailboxLoadDepth.offered) { depth in
                Text(depth.displayName).tag(depth)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(snapshot.isLoadingMore || !snapshot.hasMoreMessages)
        .help("How far a deeper read goes. Choosing a depth doesn't start one.")
        .accessibilityIdentifier("dashboard.depthPicker")
    }

    @ViewBuilder
    private var loadControls: some View {
        if snapshot.isLoadingMore {
            ProgressView().controlSize(.small)
            Button("Stop", role: .cancel) { session.cancel() }
                .help("Keeps every page loaded so far.")
                .accessibilityIdentifier("dashboard.stopLoadingButton")
        } else if snapshot.hasMoreMessages {
            Button("Load more") { session.loadMore() }
                .accessibilityIdentifier("dashboard.loadMoreButton")

            Button("Load deeper") { session.loadToDepth() }
                .buttonStyle(.borderedProminent)
                .help("Reads pages until the chosen depth is reached, or until there is no more mail. You can stop at any time.")
                .accessibilityIdentifier("dashboard.loadDeeperButton")
        }
    }
}

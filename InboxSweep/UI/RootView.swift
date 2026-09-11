import SwiftUI

/// Maps the session state onto a screen.
///
/// Every state the session can be in has a case here, so there is no path that leaves the
/// window blank or shows a spinner that never resolves.
struct RootView: View {

    let appModel: AppModel

    var body: some View {
        content
            .animation(.default, value: appModel.session.state)
            .task { await restoreIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch appModel.session.state {
        case .signedOut:
            SignedOutView(appModel: appModel)

        case .restoring:
            InboxProgressView(
                title: "Reconnecting…",
                message: "Restoring your previous \(appModel.session.providerDisplayName) connection.",
                onCancel: appModel.session.cancel
            )

        case .connecting:
            InboxProgressView(
                title: "Waiting for \(appModel.session.providerDisplayName)…",
                message: "Finish signing in and granting the permissions in the window that opened.",
                onCancel: appModel.session.cancel
            )

        case .loading(let account):
            InboxProgressView(
                title: "Reading message details…",
                message: "Loading headers for \(account.emailAddress.displayValue). Nothing is being changed.",
                onCancel: appModel.session.cancel
            )

        case .loaded(let snapshot) where snapshot.isEmpty:
            InboxEmptyView(snapshot: snapshot, session: appModel.session)

        case .loaded(let snapshot):
            SenderDashboardView(snapshot: snapshot, session: appModel.session)

        case .failed(let error, let account):
            InboxErrorView(error: error, account: account, appModel: appModel)
        }
    }

    private func restoreIfNeeded() async {
        guard case .signedOut = appModel.session.state, !appModel.isUsingSampleData else { return }
        await appModel.session.restore().value
    }
}

// Previews are development-only, and some of them run on the debug-only sample
// mailbox, so the whole block stays out of release builds.
#if DEBUG
#Preview("Signed out") {
    RootView(appModel: AppModel())
        .frame(width: 900, height: 620)
}
#endif

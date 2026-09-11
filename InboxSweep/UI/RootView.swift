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
        #if DEBUG
            // Debug-only, and inert unless the UI test launch argument was given. See
            // ``UITestWindow``.
            .onAppear(perform: UITestWindow.applyIfRequested)
            .onChange(of: appModel.session.state) { _, _ in
                UITestWindow.keepFrontmostIfRequested()
            }
            .overlay(alignment: .topLeading) { windowStateProbe }
        #endif
    }

    #if DEBUG
    /// A zero-size element carrying ``UITestWindow/Phase``, for the UI suite to wait on.
    ///
    /// Present only under the deterministic-window launch argument, so an ordinary Debug launch
    /// and every Release launch have nothing extra in their accessibility tree. It draws nothing,
    /// occupies no space, and is not focusable.
    ///
    /// It exists so a failing case can say *which* thing failed. Before it, a window that never
    /// reached its own Space failed twenty seconds later on whichever control the test reached
    /// for, with a message naming that control: the suite blamed the app for the desktop. Now the
    /// launch helper waits on this, and a harness failure reads as one.
    @ViewBuilder
    private var windowStateProbe: some View {
        if UITestWindow.isRequested {
            // `accessibilityElement(children: .ignore)` is what makes this an element at all.
            // A `Color` is not one by default, and a version of this that only set an identifier
            // and a label was published *sometimes*: it survived most launches and vanished on
            // others, which is the worst possible behaviour for the thing a case waits on. One
            // point rather than zero for the same reason.
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier(UITestWindow.stateIdentifier)
                .accessibilityLabel(UITestWindow.shared.phase.rawValue)
                .allowsHitTesting(false)
        }
    }
    #endif

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

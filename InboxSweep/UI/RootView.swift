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
    /// ### This exact shape, because the alternatives were measured and are worse
    ///
    /// A `Color` with an identifier and a label, in an overlay, at a zero frame. Three variations
    /// were tried and each was measured over a full run: `accessibilityElement(children: .ignore)`
    /// at a one-point frame, a one-point `Text` at low opacity, and moving it out of the overlay
    /// into a `ZStack` beside the content. All three were published on some launches and absent
    /// on others, and the last produced a run in which nineteen of twenty cases failed waiting
    /// for it. This is the shape that was measured to work.
    @ViewBuilder
    private var windowStateProbe: some View {
        if UITestWindow.isRequested {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityIdentifier(UITestWindow.stateIdentifier)
                .accessibilityLabel(UITestWindow.shared.phase.rawValue)
                .accessibilityHidden(false)
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

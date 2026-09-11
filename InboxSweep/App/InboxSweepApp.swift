import SwiftUI

@main
struct InboxSweepApp: App {

    @State private var appModel: AppModel

    init() {
        // Runs before any window exists and exits the process when it runs at all, so a
        // credential self-check costs one launch rather than a whole app session.
        #if DEBUG
        CredentialStoreSelfCheck.runIfRequested()
        #endif
        _appModel = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView(appModel: appModel)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 980, height: 660)
        .commands {
            // The app's only destructive-sounding verb is "Disconnect", and it disconnects
            // InboxSweep — it does not touch the mailbox.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

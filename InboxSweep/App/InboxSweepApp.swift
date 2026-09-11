import SwiftUI

@main
struct InboxSweepApp: App {

    @State private var appModel: AppModel

    init() {
        // Runs before any window exists and exits the process when it runs at all, so a
        // credential self-check costs one launch rather than a whole app session. Compiled
        // into Release as well as Debug, because the signed Release app is the build whose
        // Keychain behaviour most needs to be measurable rather than assumed; it is inert
        // without an explicit launch argument, and reaches no UI. See
        // ``CredentialStoreSelfCheck``.
        CredentialStoreSelfCheck.runIfRequested()
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
            // InboxSweep: it does not touch the mailbox.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

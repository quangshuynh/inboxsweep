import SwiftUI

@main
struct InboxSweepApp: App {

    @State private var appModel = AppModel()

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

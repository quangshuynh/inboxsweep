import Foundation

/// The launch arguments the UI tests pass to the app.
///
/// Spelled out here rather than imported, because a UI test target drives the app from *outside*
/// its process and cannot see its types. The app's own side of each of these is a `#if DEBUG`
/// constant; the two are matched by the string, and the app's declaration names this file so a
/// rename has somewhere to lead.
enum UITestLaunchArgument {

    /// Starts the app on the synthetic mailbox. Matches `AppModel.sampleDataLaunchArgument`.
    static let sampleData = "--sample-data"

    /// Starts the app with an empty, process-lifetime credential store, so the signed-out screen
    /// appears whether or not this Mac has a saved sign-in. Matches
    /// `AppModel.ignoreStoredCredentialsLaunchArgument`.
    static let ignoreStoredCredentials = "--ignore-stored-credentials"

    /// Pins the window to a fixed size, centres it, and raises it above other applications.
    /// Matches `UITestWindow.launchArgument`.
    ///
    /// Every case here passes it. Without it a case is measuring the developer's desktop: the
    /// window comes up wherever it was last left, other applications' windows lie over it, and a
    /// click on a covered control fails with an error that names InboxSweep's scroll view rather
    /// than the window that is actually in the way.
    static let deterministicWindow = "--ui-test-window"

}

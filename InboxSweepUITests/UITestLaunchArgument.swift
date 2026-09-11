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

    /// Pins the window to a fixed size, centres it, raises it above other applications, and puts
    /// it full screen. Matches `UITestWindow.launchArgument`.
    ///
    /// Every case here passes it, and every case that clicks anything **depends** on it. Without
    /// it a case is measuring the developer's desktop: the window comes up wherever it was last
    /// left, other applications' windows lie over it, and every control in the app reports
    /// `isHittable == false` — a click then fails with an error naming InboxSweep's scroll view
    /// rather than the windows that are actually in the way. Full screen is what fixes that: it
    /// gives the window a Space of its own, where there is no other application's window to be
    /// behind.
    static let deterministicWindow = "--ui-test-window"

    /// Seeds the synthetic mailbox's Activity with invented transactions, so the populated screen
    /// can be exercised. Matches `SampleActivity.launchArgument`.
    ///
    /// Only meaningful alongside ``sampleData``. It seeds *records*, not a capability: the sample
    /// session still has no mutation boundary, so the rows it produces are readable and none of
    /// them is undoable — which is the state the case asserts.
    static let sampleActivity = "--sample-activity"

    /// Gives the synthetic mailbox an in-process one-click unsubscribe boundary and an opener
    /// that opens nothing. Matches `SampleUnsubscribe.launchArgument`.
    ///
    /// Only meaningful alongside ``sampleData``. It is what makes the *confirmed* unsubscribe
    /// journeys runnable: the endpoint is `SampleUnsubscriber`, which has no transport at all,
    /// so a case can drive a confirmation all the way to an Activity row without a socket being
    /// opened or a browser being launched. Without it, the sample session has no unsubscribe
    /// boundary and its confirmation is absent rather than disabled — which is its own thing
    /// worth asserting.
    static let sampleUnsubscribe = "--sample-unsubscribe"

}

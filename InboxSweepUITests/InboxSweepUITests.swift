import XCTest

/// End-to-end checks that the window actually appears and renders each key state.
///
/// The dashboard case runs against the app's synthetic mailbox, so the whole path — launch,
/// connect, fetch, aggregate, render — is exercised without a Google account.
///
/// ### Every case launches through ``launchSampleApp()``, and two of them still fail here
///
/// Two cases in this file — ``testProposalsAndDryRunPreviewAreReachable()`` and
/// ``testSenderMessagesCanBeReviewed()`` — fail with `Unable to find hit point for ScrollView`.
/// The cause is **not** InboxSweep, and the evidence for that is unusually clean.
///
/// The split is exact: every case that only *asserts* passes, and every case that *clicks*
/// fails. The runner names the reason itself:
///
/// ```
/// Found 2 interrupting elements:
///     Window at {{839.0, 30.0}, {841.0, 927.0}} from Application 'com.brave.Browser'
///     Window at {{0.0, 30.0}, {940.0, 920.0}} from Application 'com.anthropic.claudefordesktop'
///     Window at {{360.0, 220.0}, {960.0, 640.0}} from Application 'com.apple.ActivityMonitor'
/// ```
///
/// Those three cover x ∈ [0, 1680] of the display. The window under test sits at
/// `{{240, 283}, {1200, 512}}`, entirely inside that union, so there is no point in the sender
/// table that belongs to InboxSweep when the system is asked whose window is on top. A target
/// that is not hittable sends XCUITest down its "scroll it into view" fallback, and that scroll
/// needs a hit point on the table's own backing scroll view — covered by the same windows. The
/// error names the scroll view, which is why it read for an interval like a layout bug in this
/// app. It is not one.
///
/// ### What was done about it, and what was not
///
/// ``UITestWindow`` removes the half of the problem that *is* controllable: a debug-only launch
/// argument that pins the window to a fixed size, centres it, and asks for the foreground at
/// launch and on every state change. Before it, the window came up wherever it had last been
/// dragged — 1,680 points wide across two displays — so the geometry under test was a
/// measurement of somebody's desktop. It is deterministic now.
///
/// What it cannot do is win an argument with three other applications about which window is in
/// front. Tried, in order, and none of it made the suite reliably green:
///
/// - `NSApplication.activate()`, the polite form;
/// - `NSRunningApplication.activate(options:)`, the form that does not ask;
/// - `orderFrontRegardless()` on every window, repeated on every state change;
/// - `NSWindow.Level.floating`, which made it *worse* — XCUITest's occlusion check is about
///   which application is frontmost, not about which window is drawn on top;
/// - `XCUIApplication.activate()` from the runner immediately before each click, which also
///   made it worse;
/// - clicking the table row rather than the sender's name, which XCUITest refuses outright:
///   `No unoccluded regions for Cell … Try to interact with a descendant instead.`
///
/// So the two cases are left failing, with this note, rather than made green by a sleep, a
/// retry, a raised timeout, a skip, or a swallowed assertion. On a machine with nothing else on
/// screen — a CI runner, most of all — there is no occluding window and the hit point resolves.
/// That is the next interval's to confirm, and it inherits a red it can explain rather than a
/// green it cannot trust.
final class InboxSweepUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Launching

    /// The app on synthetic data, in a window whose geometry the test controls.
    @MainActor
    private func launchSampleApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [UITestLaunchArgument.sampleData, UITestLaunchArgument.deterministicWindow]
        app.launch()
        return app
    }

    /// The clickable element for a sender in the dashboard table.
    ///
    /// Scoped to the table rather than searched for across the whole app, so a sender's name
    /// appearing somewhere else on screen cannot become the thing a test clicks.
    ///
    /// It is the sender's *name* and not the row. Clicking the row was tried, because a row is
    /// the thing that carries selection and looks like the more honest target; XCUITest refuses
    /// it, and says why: `No unoccluded regions for Cell … all the space is taken up by
    /// subviews. Try to interact with a descendant instead.` The name is that descendant.
    @MainActor
    private func senderRow(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["dashboard.senderTable"].staticTexts[name]
    }

    @MainActor
    func testSignedOutScreenExplainsWhatTheAppWillDo() {
        let app = XCUIApplication()
        // Without this the case asserts on the developer's Keychain rather than on the app: a
        // Mac with a saved Gmail sign-in restores it and lands on the dashboard, and the run
        // goes through somebody's real mailbox. The argument swaps the credential store for an
        // empty one and changes nothing else about the screen under test.
        app.launchArguments += [
            UITestLaunchArgument.ignoreStoredCredentials,
            UITestLaunchArgument.deterministicWindow,
        ]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["signedOut.title"].waitForExistence(timeout: 10),
            "The signed-out screen should appear on launch"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["privacy.notice"].exists,
            "The signed-out screen should state the privacy posture before asking for anything"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["signedOut.permissions"].exists,
            "Both Gmail permissions must be named before the user is sent to Google's consent screen"
        )
    }

    @MainActor
    func testSampleDataDrivesTheSenderDashboard() {
        let app = launchSampleApp()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15), "The dashboard should load from sample data")

        XCTAssertTrue(app.descendants(matching: .any)["dashboard.metrics"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["dashboard.accountLabel"].exists,
            "The dashboard should name the connected account"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["The Daily Digest"].waitForExistence(timeout: 5),
            "The sender list should show the synthetic senders"
        )
    }

    /// The Interval 3 path end to end: a proposal on the row, its reasoning in the inspector,
    /// and a dry-run preview that states it changes nothing.
    ///
    /// Driven through the real UI because the reasoning and the preview are the parts a user
    /// has to be able to trust, and a unit test cannot show that they actually reach the screen.
    @MainActor
    func testProposalsAndDryRunPreviewAreReachable() {
        let app = launchSampleApp()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15), "The dashboard should load from sample data")

        XCTAssertTrue(
            app.descendants(matching: .any)["dashboard.filterPicker"].exists,
            "The dashboard should offer proposal filters"
        )

        let previewButton = app.buttons["dashboard.previewCleanupButton"]
        XCTAssertTrue(previewButton.exists)
        XCTAssertFalse(previewButton.isEnabled, "Previewing needs a selection first")

        let sender = senderRow(named: "Storefront Deals", in: app)
        XCTAssertTrue(sender.waitForExistence(timeout: 5))
        sender.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["senderDetail.proposal"].waitForExistence(timeout: 5),
            "Selecting a sender should show the reasoning behind its proposal"
        )
        XCTAssertTrue(previewButton.isEnabled, "A selected sender can be previewed")

        previewButton.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["cleanupPlan.screen"].waitForExistence(timeout: 5),
            "The dry-run preview should open"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["cleanupPlan.disclaimer"].exists,
            "The preview must say it changes nothing before it says what it would reach"
        )
        XCTAssertTrue(app.descendants(matching: .any)["cleanupPlan.totals"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["cleanupPlan.windowNotice"].exists,
            "The preview must say which slice of the mailbox its numbers describe"
        )

        // There is no confirm, delete, or clean-now control to find, only a way out.
        XCTAssertFalse(app.buttons["Delete"].exists)
        XCTAssertFalse(app.buttons["Trash now"].exists)
        app.buttons["cleanupPlan.doneButton"].click()
    }

    /// The Interval 4 path: the dashboard states how much mail it has analysed, and offers the
    /// controls that change it.
    ///
    /// Driven through the real UI because coverage is the claim most easily overstated — a
    /// dashboard that quietly implied it had read the whole mailbox would mislead the user at
    /// exactly the moment they are weighing a suggestion.
    @MainActor
    func testDashboardStatesHowMuchMailHasBeenAnalysed() {
        let app = launchSampleApp()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15), "The dashboard should load from sample data")

        XCTAssertTrue(
            app.descendants(matching: .any)["dashboard.coverageHeadline"].exists,
            "The dashboard must say how many messages it has actually loaded"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["dashboard.coverageDetail"].exists,
            "…and whether there is more it has not read"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["dashboard.scopePicker"].exists,
            "The dashboard should let the user choose which part of the mailbox to read"
        )
    }

    /// Activity has a way in from the dashboard, and nothing on that screen can change a mailbox.
    ///
    /// ### Why this case stops at the button
    ///
    /// It asserts the entry point and not the journey, which is less than it should be. The
    /// reason is specific and was measured rather than assumed: **XCUITest cannot click a
    /// SwiftUI toolbar button in this app at all.** Toolbar items report `isHittable == false`,
    /// the runner falls back to synthesising a click at the element's centre, and nothing
    /// happens. That is not new and not about Activity — ``dashboard.disconnectButton`` behaves
    /// identically, and it predates this interval by five of them. It is also not the occlusion
    /// problem this class describes above: with every other application's window hidden, the
    /// runner reported no interrupting elements, clicked the button, and the app did not react.
    ///
    /// Two ways out were tried and rejected. A debug launch argument that opened Activity at
    /// launch does not work either — a `.sheet` whose item is already set when the view first
    /// appears never presents, because SwiftUI presents on the *transition* — and moving the
    /// control out of the toolbar to suit the test would be letting the test design the app.
    ///
    /// So the screen behind this button is covered where it can be covered honestly: the
    /// wording, counts, states, and undo rules are `MutationHistoryTests` and
    /// `ActivityHistoryTests`, and the screen itself was verified by hand — it opens, shows the
    /// empty state, and states its scope and its retention. See `Docs/Activity.md`.
    @MainActor
    func testActivityIsReachableAndCannotChangeAnything() {
        let app = launchSampleApp()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15), "The dashboard should load from sample data")

        XCTAssertTrue(
            app.buttons["dashboard.activityButton"].waitForExistence(timeout: 5),
            "The dashboard should offer a way into Activity"
        )

        // Activity is not open, and nothing about having a way into it puts a mutation control
        // on the dashboard. The synthetic mailbox vends no mutation boundary at all, so this is
        // the app's guarantee that a sample run cannot reach a write even by accident.
        XCTAssertFalse(app.descendants(matching: .any)["activity.screen"].exists)
        XCTAssertFalse(app.buttons["activity.undoButton"].exists)
        XCTAssertFalse(app.buttons["Archive"].exists)
        XCTAssertFalse(app.buttons["Delete"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["archiveSheet.screen"].exists)
    }

    /// Opening the messages behind a sender's proposal, which is what makes a count checkable.
    @MainActor
    func testSenderMessagesCanBeReviewed() {
        let app = launchSampleApp()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))

        let sender = senderRow(named: "Storefront Deals", in: app)
        XCTAssertTrue(sender.waitForExistence(timeout: 5))
        sender.click()

        // Reached from the preview rather than from the inspector: the inspector's own entry
        // point sits below a long reasoning list and is not reliably on screen at the window
        // size the runner picks. Both open the same review.
        let previewButton = app.buttons["dashboard.previewCleanupButton"]
        XCTAssertTrue(previewButton.waitForExistence(timeout: 5))
        previewButton.click()

        XCTAssertTrue(app.descendants(matching: .any)["cleanupPlan.screen"].waitForExistence(timeout: 5))

        // Queried across all element types: a link-styled button reports itself as a link.
        let reviewButton = app.descendants(matching: .any)["cleanupPlan.reviewButton"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 5), "The preview should offer a message review")
        reviewButton.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["messageReview.screen"].waitForExistence(timeout: 5),
            "The message review should open"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["messageReview.disclaimer"].exists,
            "The review must say it changes nothing before it shows anything"
        )
        XCTAssertTrue(app.descendants(matching: .any)["messageReview.table"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["messageReview.sortPicker"].exists,
            "The review should be sortable"
        )

        // The sample mailbox is not a real account, so `SampleMailProvider` vends no mutation
        // boundary and the Archive control is absent rather than disabled. That absence is
        // worth asserting: it is the app's guarantee that a synthetic run cannot reach a write
        // even by accident, and it holds because there is no archiver, not because a view
        // remembered to check.
        XCTAssertFalse(app.buttons["messageReview.archiveButton"].exists)
        XCTAssertFalse(app.buttons["messageReview.enableArchivingButton"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["archiveSheet.screen"].exists)
        XCTAssertFalse(app.buttons["Archive"].exists)
        XCTAssertFalse(app.buttons["Delete"].exists)
        XCTAssertFalse(app.buttons["Unsubscribe"].exists)
        app.descendants(matching: .any)["messageReview.doneButton"].firstMatch.click()
    }
}

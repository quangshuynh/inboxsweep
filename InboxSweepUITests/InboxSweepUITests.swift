import XCTest

/// End-to-end checks that the window actually appears and renders each key state.
///
/// The dashboard case runs against the app's synthetic mailbox, so the whole path — launch,
/// connect, fetch, aggregate, render — is exercised without a Google account.
///
/// ### Every case launches through ``launchSampleApp()``, and that is what makes them pass
///
/// For two intervals, every case here that *clicked* anything failed with `Unable to find hit
/// point for ScrollView`, and every case that only *asserted* passed. The previous interval read
/// that as two separate problems — an occluded sender table, and a SwiftUI toolbar button
/// XCUITest could not press. It was one problem, and neither half was about InboxSweep.
///
/// Measured rather than assumed: with the developer's other windows on screen, `isHittable` is
/// `false` for the sender name, for the *Preview cleanup* button, for the filter picker, and for
/// a line of static text in the footer. Nothing in the app was reachable, because two other
/// applications' windows covered the full width of the display and macOS refused the activation
/// that would have put the app in front. The toolbar was never the problem; it was one more
/// control on a window no click could reach.
///
/// ``UITestWindow`` now puts the window under test **full screen**, which gives it a Space of its
/// own where no other application's window exists to occlude it. Both long-red cases pass, and so
/// does the journey this interval adds. No sleep, retry, skip, or raised timeout is involved, and
/// a control that is genuinely unreachable still fails.
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

    /// Activity is reachable from the content, opens, states its scope, and can change nothing.
    ///
    /// ### Why it goes through the in-content route
    ///
    /// The toolbar button is still there and still the primary way in. This drives the link in
    /// the dashboard footer instead, for a reason that is about the product rather than about the
    /// runner: a toolbar is a place a control can be hard to get at — collapsed into an overflow
    /// menu on a narrow window, and unreachable to anything driving the app from outside — and
    /// "what has this app changed?" deserves an answer that does not depend on one. The journey
    /// behind both is identical, so testing the reachable one covers the behaviour rather than
    /// proving XCUITest can press a macOS toolbar button.
    @MainActor
    func testActivityIsReachableFromTheContentAndCannotChangeAnything() {
        let app = launchSampleApp()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15), "The dashboard should load from sample data")

        // Both routes exist. Only one of them is driven.
        XCTAssertTrue(
            app.buttons["dashboard.activityButton"].exists,
            "The toolbar route into Activity should still be there"
        )

        let activityLink = app.descendants(matching: .any)["dashboard.activityLink"]
        XCTAssertTrue(
            activityLink.waitForExistence(timeout: 5),
            "The dashboard content should offer a way into Activity"
        )
        activityLink.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["activity.screen"].waitForExistence(timeout: 5),
            "The in-content route should open Activity"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["activity.scopeNote"].exists,
            "Activity must say what it does and does not record before it lists anything"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["activity.retentionNote"].exists,
            "Activity must say that the history is bounded"
        )

        // The empty state, reached honestly: the synthetic mailbox vends no mutation boundary, so
        // a sample run cannot have changed anything and there is nothing to list.
        XCTAssertTrue(
            app.descendants(matching: .any)["activity.empty"].waitForExistence(timeout: 5),
            "A session that has changed nothing should show the empty state"
        )

        // Nothing on the screen can reach a mailbox, and the undo is absent rather than disabled.
        XCTAssertFalse(app.buttons["activity.undoButton"].exists)
        XCTAssertFalse(app.buttons["Archive"].exists)
        XCTAssertFalse(app.buttons["Delete"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["archiveSheet.screen"].exists)

        app.descendants(matching: .any)["activity.doneButton"].firstMatch.click()
        XCTAssertTrue(table.waitForExistence(timeout: 5), "Closing Activity should return to the dashboard")
    }

    /// Activity with something in it: the rows render, a row opens, and none of it is actionable.
    ///
    /// ### Why the history is seeded rather than performed
    ///
    /// It cannot be performed here. The synthetic mailbox vends no mutation boundary, so a sample
    /// run has nothing that could produce a transaction — which is the right design and is what
    /// every other case in this file relies on. ``SampleActivity`` therefore seeds the *records*
    /// into an in-memory store. That adds no capability: the session still cannot write, and the
    /// newest seeded archive is marked undoable in the file and is still not offered, because the
    /// grant behind it does not exist. This case asserts exactly that.
    @MainActor
    func testActivityShowsSeededHistoryAndStillCannotChangeAnything() {
        let app = XCUIApplication()
        app.launchArguments += [
            UITestLaunchArgument.sampleData,
            UITestLaunchArgument.sampleActivity,
            UITestLaunchArgument.deterministicWindow,
        ]
        app.launch()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15), "The dashboard should load from sample data")

        let activityLink = app.descendants(matching: .any)["dashboard.activityLink"]
        XCTAssertTrue(activityLink.waitForExistence(timeout: 5))
        activityLink.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["activity.screen"].waitForExistence(timeout: 5),
            "The in-content route should open Activity"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["activity.list"].waitForExistence(timeout: 5),
            "A history with entries should be listed rather than showing the empty state"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["activity.empty"].exists,
            "A populated history showed the empty state"
        )

        // Opening a row is a read. It resolves what the window can still describe and says so
        // when it cannot, which is the graceful degradation the privacy model depends on.
        let rows = app.descendants(matching: .any).matching(identifier: "activity.row")
        XCTAssertGreaterThan(rows.count, 1, "The seeded history should have several entries")
        rows.element(boundBy: 0).click()

        XCTAssertTrue(
            app.descendants(matching: .any)["activity.detail.tallies"].waitForExistence(timeout: 5),
            "Opening a change should show what it did"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["activity.detail.explanation"].exists,
            "A change must explain itself, not just count"
        )

        // The whole point: being visible did not make anything actionable. The newest seeded
        // archive is undoable in the record and is not offered, because this session has no
        // mutation boundary to honour it with.
        XCTAssertFalse(app.buttons["activity.undoButton"].exists)
        XCTAssertFalse(app.buttons["Archive"].exists)
        XCTAssertFalse(app.buttons["Delete"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["archiveSheet.screen"].exists)

        app.descendants(matching: .any)["activity.doneButton"].firstMatch.click()
    }

    /// The sender-level entry point: it exists, it opens a review, and it archives nothing.
    ///
    /// The wording is asserted as well as the navigation. **Review messages to archive…** is the
    /// promise the interval makes — that pressing it moves you into a review rather than carrying
    /// something out — and a later rename to *Archive sender* would be a different product.
    @MainActor
    func testSenderCleanupOpensAReviewRatherThanArchiving() {
        let app = launchSampleApp()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))

        let sender = senderRow(named: "Storefront Deals", in: app)
        XCTAssertTrue(sender.waitForExistence(timeout: 5))
        sender.click()

        let previewButton = app.buttons["dashboard.previewCleanupButton"]
        XCTAssertTrue(previewButton.waitForExistence(timeout: 5))
        previewButton.click()
        XCTAssertTrue(app.descendants(matching: .any)["cleanupPlan.screen"].waitForExistence(timeout: 5))

        // Queried across all element types: a link-styled button reports itself as a link.
        let cleanupReview = app.descendants(matching: .any)["cleanupPlan.reviewCleanupButton"]
        XCTAssertTrue(
            cleanupReview.waitForExistence(timeout: 5),
            "A sender's preview row should offer a way to review the messages it names"
        )
        cleanupReview.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["messageReview.screen"].waitForExistence(timeout: 5),
            "The sender-level action should open the message review"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["messageReview.preselectionSummary"].waitForExistence(timeout: 5),
            "The review should say what it preselected, or why it preselected nothing"
        )

        // The whole point of the interval: the convenience got the user to a review, and stopped.
        // On the synthetic mailbox there is no archiver at all, so the Archive control is absent
        // rather than disabled — which is the app's guarantee that a sample run cannot reach a
        // write even by accident.
        XCTAssertFalse(app.descendants(matching: .any)["archiveSheet.screen"].exists)
        XCTAssertFalse(app.buttons["messageReview.archiveButton"].exists)
        XCTAssertFalse(app.buttons["Archive sender"].exists)
        XCTAssertFalse(app.buttons["Clean sender"].exists)
        XCTAssertFalse(app.buttons["Apply recommendation"].exists)
        XCTAssertFalse(app.buttons["Archive all from sender"].exists)

        app.descendants(matching: .any)["messageReview.doneButton"].firstMatch.click()
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

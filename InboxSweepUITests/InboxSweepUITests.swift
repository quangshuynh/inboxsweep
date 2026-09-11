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
    private func launchSampleApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [UITestLaunchArgument.sampleData, UITestLaunchArgument.deterministicWindow]
        app.launchArguments += extraArguments
        app.launch()
        return app
    }

    /// Opens Activity through the in-content link, which is the route Interval 9 made reliable.
    @MainActor
    private func openActivity(in app: XCUIApplication) {
        let link = app.descendants(matching: .any)["dashboard.activityLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "The dashboard should offer a way into Activity")
        link.click()
        XCTAssertTrue(app.descendants(matching: .any)["activity.screen"].waitForExistence(timeout: 5))
    }

    /// Opens one sender's message review, which is where every clickable entry point lives.
    ///
    /// Reached through the dry-run preview rather than through the inspector, for the reason
    /// `testSenderMessagesCanBeReviewed` already records: the inspector's own entry points sit
    /// below a long reasoning list inside a scroll view and are not reliably on screen at the
    /// window size the runner picks. Both routes open the same screens.
    @MainActor
    private func openMessageReview(for sender: String, in app: XCUIApplication) {
        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))

        let row = senderRow(named: sender, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()

        let previewButton = app.buttons["dashboard.previewCleanupButton"]
        XCTAssertTrue(previewButton.waitForExistence(timeout: 5))
        previewButton.click()
        XCTAssertTrue(app.descendants(matching: .any)["cleanupPlan.screen"].waitForExistence(timeout: 5))

        // Queried across all element types: a link-styled button reports itself as a link.
        let reviewButton = app.descendants(matching: .any)["cleanupPlan.reviewButton"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 5))
        reviewButton.firstMatch.click()

        XCTAssertTrue(app.descendants(matching: .any)["messageReview.screen"].waitForExistence(timeout: 5))
    }

    /// Opens one sender's unsubscribe options from the message review.
    @MainActor
    private func openUnsubscribeOptions(for sender: String, in app: XCUIApplication) {
        openMessageReview(for: sender, in: app)

        let button = app.buttons["messageReview.unsubscribeButton"]
        XCTAssertTrue(
            button.waitForExistence(timeout: 5),
            "A sender whose headers mention unsubscribing should offer to show the options"
        )
        button.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["unsubscribeOptions.screen"].waitForExistence(timeout: 5),
            "The unsubscribe options should open"
        )
    }

    /// Closes the unsubscribe options and the message review behind it.
    @MainActor
    private func closeUnsubscribeOptions(in app: XCUIApplication) {
        app.descendants(matching: .any)["unsubscribeOptions.doneButton"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["messageReview.screen"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["messageReview.doneButton"].firstMatch.click()
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

        // Interval 10 added an unsubscribe entry point to this screen, so the blanket assertion
        // that used to live here — no button called "Unsubscribe" — became the wrong claim. The
        // right one is narrower and stronger: the control that *opens a reading* may be here,
        // and nothing that acts is. No confirmation sheet, and no verb that would perform one.
        XCTAssertFalse(app.descendants(matching: .any)["unsubscribeSheet.screen"].exists)
        XCTAssertFalse(app.buttons["Send the request"].exists)
        XCTAssertFalse(app.buttons["Stop all mail"].exists)
        XCTAssertFalse(app.buttons["Block sender"].exists)
        XCTAssertFalse(app.buttons["Unsubscribe from sender"].exists)

        app.descendants(matching: .any)["messageReview.doneButton"].firstMatch.click()
    }

    // MARK: - Unsubscribe

    /// A sender whose mail says nothing about unsubscribing offers nothing, and says why.
    @MainActor
    func testSenderWithNoUnsubscribeOptionSaysSo() {
        let app = launchSampleApp()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))

        // `alerts@example.org` carries no List-Unsubscribe header at all in the synthetic
        // mailbox, which is the "no evidence" state.
        openMessageReview(for: "alerts@example.org", in: app)

        XCTAssertFalse(
            app.buttons["messageReview.unsubscribeButton"].exists,
            "A sender with no unsubscribe metadata should offer no unsubscribe entry point at all"
        )
        XCTAssertFalse(app.descendants(matching: .any)["messageReview.unsubscribeDistinctionNote"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["unsubscribeOptions.screen"].exists)

        app.descendants(matching: .any)["messageReview.doneButton"].firstMatch.click()
    }

    /// The one-click journey as far as the confirmation, and no further.
    @MainActor
    func testOneClickUnsubscribeShowsItsDestinationBeforeConfirming() {
        let app = launchSampleApp(extraArguments: [UITestLaunchArgument.sampleUnsubscribe])

        openUnsubscribeOptions(for: "The Daily Digest", in: app)

        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeOptions.scopeNote"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["unsubscribeOptions.futureMailNote"].exists,
            "The options screen must say this is about future mail before offering anything"
        )

        let reviewButton = app.descendants(matching: .any)["unsubscribeOptions.reviewButton"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 5))
        reviewButton.click()

        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.screen"].waitForExistence(timeout: 5))

        // The three things this screen exists to say, before anything can happen.
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.destination"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.destinationHost"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.futureMailNote"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.evidence"].exists)

        // The first press opens a second, dedicated confirmation rather than acting.
        let actionButton = app.buttons["unsubscribeSheet.actionButton"]
        XCTAssertTrue(actionButton.waitForExistence(timeout: 5))
        actionButton.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["unsubscribeSheet.confirmPrompt"].waitForExistence(timeout: 5),
            "Acting must be gated behind a dedicated confirmation immediately before the request"
        )
        XCTAssertTrue(app.buttons["unsubscribeSheet.confirmButton"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)["unsubscribeSheet.outcome"].exists,
            "Nothing may have happened yet"
        )
    }

    /// Cancelling at the confirmation step leaves nothing behind.
    @MainActor
    func testCancellingAConfirmationPerformsNothing() {
        let app = launchSampleApp(extraArguments: [UITestLaunchArgument.sampleUnsubscribe])

        openUnsubscribeOptions(for: "The Daily Digest", in: app)
        app.descendants(matching: .any)["unsubscribeOptions.reviewButton"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.screen"].waitForExistence(timeout: 5))

        app.buttons["unsubscribeSheet.actionButton"].click()
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.confirmPrompt"].waitForExistence(timeout: 5))

        // "Not now" backs out of the confirmation without acting.
        app.buttons["unsubscribeSheet.cancelButton"].click()
        XCTAssertFalse(app.descendants(matching: .any)["unsubscribeSheet.outcome"].exists)

        // And "Cancel" closes the sheet.
        app.buttons["unsubscribeSheet.cancelButton"].click()
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeOptions.screen"].waitForExistence(timeout: 5))
        closeUnsubscribeOptions(in: app)

        // Nothing reached Activity, because nothing was performed.
        openActivity(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["activity.empty"].waitForExistence(timeout: 5),
            "Opening and cancelling a review must leave no Activity entry"
        )
    }

    /// A confirmed one-click, against the in-process endpoint, and the Activity row it leaves.
    @MainActor
    func testConfirmedOneClickUnsubscribeIsRecordedCautiously() {
        let app = launchSampleApp(extraArguments: [UITestLaunchArgument.sampleUnsubscribe])

        openUnsubscribeOptions(for: "The Daily Digest", in: app)
        app.descendants(matching: .any)["unsubscribeOptions.reviewButton"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.screen"].waitForExistence(timeout: 5))

        app.buttons["unsubscribeSheet.actionButton"].click()
        let confirm = app.buttons["unsubscribeSheet.confirmButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["unsubscribeSheet.outcome"].waitForExistence(timeout: 10),
            "The result should appear once the endpoint has answered"
        )
        // The wording the whole interval turns on, and the absence of an undo offer.
        XCTAssertTrue(app.staticTexts["Unsubscribe request sent"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["unsubscribeSheet.cannotConfirmNote"].exists,
            "The result must say InboxSweep cannot see whether the sender acted on it"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["unsubscribeSheet.noUndoNote"].exists,
            "The result must say there is no undo, rather than quietly not offering one"
        )
        XCTAssertFalse(app.staticTexts["You are unsubscribed"].exists)
        XCTAssertFalse(app.buttons["Undo"].exists)

        app.buttons["unsubscribeSheet.doneButton"].click()
        closeUnsubscribeOptions(in: app)

        openActivity(in: app)
        let row = app.descendants(matching: .any)["activity.unsubscribeRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The unsubscribe should appear in Activity")
        row.click()

        XCTAssertTrue(app.descendants(matching: .any)["activity.unsubscribeDetail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["activity.unsubscribeDetail.host"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["activity.unsubscribeDetail.noUndo"].exists,
            "An unsubscribe row must say why there is no undo rather than silently offering none"
        )
        XCTAssertFalse(app.buttons["activity.undoButton"].exists)
    }

    /// A sender whose only mechanisms are a web page and a mail address.
    @MainActor
    func testBrowserAndMailHandoffsAreLabelledAsHandoffs() {
        let app = launchSampleApp(extraArguments: [UITestLaunchArgument.sampleUnsubscribe])

        // Storefront Deals offers an https page and a mailto, and declares no one-click.
        openUnsubscribeOptions(for: "Storefront Deals", in: app)
        app.descendants(matching: .any)["unsubscribeOptions.reviewButton"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.screen"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.staticTexts["Unsubscribe page"].exists, "A plain https URL is a page, not a one-click endpoint")
        XCTAssertTrue(app.staticTexts["Your browser opens the page"].exists)
        XCTAssertTrue(app.buttons["unsubscribeSheet.actionButton"].exists)

        // The alternatives sit at the bottom of a scrolling sheet, below the evidence, so the
        // case scrolls to them rather than asserting they happen to be on screen at whatever
        // height the runner picked.
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(
            app.descendants(matching: .any)["unsubscribeSheet.alternatives"].waitForExistence(timeout: 5),
            "A sender offering more than one mechanism must show the others rather than choosing silently"
        )
        app.buttons["unsubscribeSheet.cancelButton"].click()
        closeUnsubscribeOptions(in: app)
    }

    /// A mail-only sender says the message is prepared, not sent.
    @MainActor
    func testMailHandoffSaysItWillNotSend() {
        let app = launchSampleApp(extraArguments: [UITestLaunchArgument.sampleUnsubscribe])

        openUnsubscribeOptions(for: "Frontend Weekly", in: app)
        app.descendants(matching: .any)["unsubscribeOptions.reviewButton"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.screen"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.staticTexts["Email unsubscribe"].exists)
        XCTAssertTrue(app.staticTexts["Your mail app opens a message"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.whatHappens"].exists)
        app.buttons["unsubscribeSheet.cancelButton"].click()
        closeUnsubscribeOptions(in: app)
    }

    /// Metadata the parser refused explains itself and offers nothing to press.
    @MainActor
    func testMalformedMetadataCannotBeActedOn() {
        let app = launchSampleApp(extraArguments: [UITestLaunchArgument.sampleUnsubscribe])

        // The Café Bulletin's synthetic header holds an http link and an unbracketed value.
        openUnsubscribeOptions(for: "Café Bulletin", in: app)

        XCTAssertTrue(
            app.descendants(matching: .any)["unsubscribeOptions.unavailable"].waitForExistence(timeout: 5),
            "Refused metadata must be explained rather than shown as an empty screen"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["unsubscribeOptions.reviewButton"].exists,
            "Metadata InboxSweep refused must not be reviewable, let alone actionable"
        )
        XCTAssertFalse(app.descendants(matching: .any)["unsubscribeSheet.screen"].exists)
        closeUnsubscribeOptions(in: app)
    }

    /// Without the sample unsubscribe boundary, detection still works and execution is absent.
    @MainActor
    func testWithoutABoundaryDetectionStillWorksAndNothingCanBeSent() {
        let app = launchSampleApp()

        openUnsubscribeOptions(for: "The Daily Digest", in: app)

        // The reading is there: detection needs no boundary.
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeOptions.availability"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeOptions.evidence"].exists)

        // The review can be opened — it performs nothing — but the request cannot be sent.
        app.descendants(matching: .any)["unsubscribeOptions.reviewButton"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.screen"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["unsubscribeSheet.actionButton"].isEnabled,
            "A session with no unsubscribe boundary must not be able to send a one-click request"
        )
        app.buttons["unsubscribeSheet.cancelButton"].click()
        closeUnsubscribeOptions(in: app)
    }
}

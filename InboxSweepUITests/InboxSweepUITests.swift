import XCTest

/// End-to-end checks that the window actually appears and renders each key state.
///
/// The dashboard case runs against the app's synthetic mailbox, so the whole path — launch,
/// connect, fetch, aggregate, render — is exercised without a Google account.
final class InboxSweepUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSignedOutScreenExplainsWhatTheAppWillDo() {
        let app = XCUIApplication()
        // Without this the case asserts on the developer's Keychain rather than on the app: a
        // Mac with a saved Gmail sign-in restores it and lands on the dashboard, and the run
        // goes through somebody's real mailbox. The argument swaps the credential store for an
        // empty one and changes nothing else about the screen under test.
        app.launchArguments += ["--ignore-stored-credentials"]
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
        let app = XCUIApplication()
        app.launchArguments += ["--sample-data"]
        app.launch()

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
        let app = XCUIApplication()
        app.launchArguments += ["--sample-data"]
        app.launch()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15), "The dashboard should load from sample data")

        XCTAssertTrue(
            app.descendants(matching: .any)["dashboard.filterPicker"].exists,
            "The dashboard should offer proposal filters"
        )

        let previewButton = app.buttons["dashboard.previewCleanupButton"]
        XCTAssertTrue(previewButton.exists)
        XCTAssertFalse(previewButton.isEnabled, "Previewing needs a selection first")

        let sender = app.staticTexts["Storefront Deals"]
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
        let app = XCUIApplication()
        app.launchArguments += ["--sample-data"]
        app.launch()

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

    /// Opening the messages behind a sender's proposal, which is what makes a count checkable.
    @MainActor
    func testSenderMessagesCanBeReviewed() {
        let app = XCUIApplication()
        app.launchArguments += ["--sample-data"]
        app.launch()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))

        let sender = app.staticTexts["Storefront Deals"]
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

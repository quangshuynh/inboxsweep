import XCTest

/// End-to-end checks that the window actually appears and renders each key state.
///
/// The dashboard case runs against the app's synthetic mailbox, so the whole path (launch,
/// connect, fetch, aggregate, render) is exercised without a Google account.
///
/// ### Every case launches through ``launchSampleApp()``, and that is what makes them pass
///
/// For two intervals, every case here that *clicked* anything failed with `Unable to find hit
/// point for ScrollView`, and every case that only *asserted* passed. Interval 9 read that as two
/// separate problems: an occluded sender table, and a SwiftUI toolbar button XCUITest could not
/// press. It was one problem, and neither half was about InboxSweep.
///
/// Measured rather than assumed: with the developer's other windows on screen, `isHittable` is
/// `false` for the sender name, for the *Preview cleanup* button, for the filter picker, and for
/// a line of static text in the footer. Nothing in the app was reachable, because two other
/// applications' windows covered the full width of the display and macOS refused the activation
/// that would have put the app in front. The toolbar was never the problem; it was one more
/// control on a window no click could reach.
///
/// ``UITestWindow`` puts the window under test **full screen**, which gives it a Space of its own
/// where no other application's window exists to occlude it.
///
/// ### What Interval 11 found still wrong, and fixed
///
/// Interval 10 left this suite green but not *reliably* green: six of eleven consecutive full
/// runs had one failure, spread across unrelated cases. Interval 11 reproduced it on the first
/// run and found two causes, both in this harness and neither in the product.
///
/// **The window placement was not idempotent, and nobody checked it.** Interval 9 issued one
/// `toggleFullScreen` on the first `onAppear` and assumed it worked. Terminating an app that owns
/// a full-screen Space destroys that Space, and a request issued while macOS is tearing the old
/// one down is dropped with no error. The window then stays on the shared desktop for the whole
/// case, which is the Interval 9 symptom exactly. ``UITestWindow`` now re-asserts the request,
/// bounded, until the window's own `styleMask` says it is full screen, and publishes how far it
/// got; ``waitForDeterministicWindow(_:)`` waits for that before a case touches anything.
///
/// **Hittable is not the same as clickable.** A disabled SwiftUI button exists and is hittable,
/// so `clickWhenReady` was waiting for a state that a swallowed click satisfies. See
/// ``clickWhenReady(_:in:_:file:line:)`` for the runner log of a failure caused by exactly that.
/// It now waits for `isHittable && isEnabled`, and every click in this file goes through it.
///
/// No sleep, retry, skip, or weakened assertion is involved in any of that. Both changes make the
/// suite assert *more* than it did, and a control that is genuinely unreachable still fails.
final class InboxSweepUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// How long a case waits for the sample dashboard to appear after launching the app.
    ///
    /// Raised from 15 seconds in Interval 10, for a reason about this suite rather than about
    /// the app. The unsubscribe journeys doubled the number of launches, eight cases became
    /// sixteen, and a run of the whole test plan now launches, connects, and tears down the app
    /// sixteen times in a row on the same machine that is also running the unit target. Three
    /// cases timed out at 15 seconds in that configuration, including two that predate this
    /// interval and touch nothing it changed, while the same cases passed when the UI target ran
    /// on its own.
    ///
    /// This is **not** a loosened assertion. The case still fails if the dashboard never
    /// appears, and no retry, sleep, or skip was added: a launch that is genuinely broken is
    /// still a red case. What changed is the budget, to match a suite that now asks twice as
    /// much of the machine.
    private static let dashboardLoadTimeout: TimeInterval = 45

    /// How long a case waits for a screen or control to appear after clicking something.
    ///
    /// Raised from 5 seconds alongside ``dashboardLoadTimeout``, for the same reason and with
    /// the same caveat. A sheet presenting after a click is fast when the machine is idle and is
    /// not always fast when sixteen app launches and a full unit target have just run on it.
    /// The case that caught this was `testActivityIsReachableFromTheContentAndCannotChangeAnything`,
    /// which this interval does not touch, timing out waiting for Activity to present.
    ///
    /// Again: no assertion was weakened, and nothing was retried, slept on, or skipped. A
    /// control that never appears still fails the case.
    private static let elementTimeout: TimeInterval = 20

    /// How long a launch is given to reach its deterministic window.
    ///
    /// Sized against the app's own bound rather than against a hope: `UITestWindow` re-issues the
    /// full-screen request at most five times, two seconds apart, and then reports
    /// `unavailable` rather than continuing to try. Twenty-five seconds therefore covers the
    /// app's entire retry budget with room for the launch itself, and a window that is going to
    /// arrive has arrived long before it. Nothing here retries a test or relaxes an assertion:
    /// this bound is reached only when the app has already said it failed.
    private static let windowReadyTimeout: TimeInterval = 25

    // MARK: - Launching

    /// The app on synthetic data, in a window whose geometry the test controls.
    ///
    /// It does not return until the app reports its window is full screen, key, and frontmost.
    /// See ``waitForDeterministicWindow(_:)`` for why that wait is here rather than left to the
    /// first control each case happens to reach for.
    @MainActor
    private func launchSampleApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [UITestLaunchArgument.sampleData, UITestLaunchArgument.deterministicWindow]
        app.launchArguments += extraArguments
        app.launch()
        waitForDeterministicWindow(app)
        return app
    }

    /// Waits for the app to say its window reached the state every click in this file depends on.
    ///
    /// ### Why this is the first thing every case does
    ///
    /// Because without it the suite blames the app for the desktop. Measured on this machine,
    /// with the Interval 9 harness: `testConfirmedOneClickUnsubscribeIsRecordedCautiously`,
    /// launched straight after a case that had itself timed out, found the sender table at
    /// t=6.7s, waited twenty seconds for a sender's name to appear in it, then polled
    /// `isHittable` for twenty more and failed. Nothing was wrong with the sender row. The window
    /// had never reached its own Space, because terminating the previous app destroys the Space
    /// it owned and a `toggleFullScreen` issued during that teardown is dropped, so the developer's
    /// other windows were over it for the whole case.
    ///
    /// `UITestWindow` now recovers from that by asking again, and publishes how far it got. This
    /// waits for the answer. Two things follow, and both are the point:
    ///
    /// - a case that *would* have failed on a dropped transition now passes, because the app
    ///   re-issues the request instead of assuming the first one landed;
    /// - a case that fails anyway fails **here**, saying the window never became deterministic,
    ///   rather than twenty seconds later naming a control that was never the problem.
    ///
    /// This is a bounded wait on a real observable state, not a sleep, a retry, or a raised
    /// assertion timeout. The state it waits for is the window's own `styleMask`, key status, and
    /// its application's active status, reported by the app under test.
    @MainActor
    private func waitForDeterministicWindow(_ app: XCUIApplication) {
        front(app)
        let probe = app.descendants(matching: .any)[UITestLaunchArgument.windowStateIdentifier]
        let ready = expectation(
            for: NSPredicate(format: "label == %@", UITestLaunchArgument.windowIsReady),
            evaluatedWith: probe
        )
        guard XCTWaiter.wait(for: [ready], timeout: Self.windowReadyTimeout) == .completed else {
            XCTFail(
                "The window never became deterministic. \(windowStateReport(app)) "
                + "'\(UITestLaunchArgument.windowIsUnavailable)' means macOS refused the "
                + "full-screen transition every time it was asked, and anything else means it "
                + "never finished. Nothing about the product under test has been exercised."
            )
            return
        }
    }

    /// What the runner can see of the app, for a failure message.
    ///
    /// ### Why this separates "no window" from "not ready"
    ///
    /// Because they have completely different causes and only one of them is about this app.
    /// Measured while writing this: a state in which XCUITest reported the application element as
    /// `Disabled` with **no children at all** for every case in the suite, and reproduced it with
    /// the deterministic-window argument removed entirely, which is proof the harness was not
    /// involved. An app whose windows the runner cannot see is a machine to fix, not a test to
    /// rewrite, and the message says so rather than leaving somebody to infer it.
    ///
    /// Read defensively in every direction: an element that is not in the tree raises when asked
    /// anything, and raising inside a failure message replaces a diagnosis with a snapshot error.
    @MainActor
    private func windowStateReport(_ app: XCUIApplication) -> String {
        let probe = app.descendants(matching: .any)[UITestLaunchArgument.windowStateIdentifier]
        if probe.exists { return "The app last reported '\(probe.label)'." }
        guard app.windows.firstMatch.exists else {
            return "The runner can see no window of this app at all, which usually means the "
                + "machine's UI-testing permissions need attention rather than that the app is "
                + "broken: check that Xcode has Accessibility access. It is reproducible without "
                + "\(UITestLaunchArgument.deterministicWindow), so it is not the window placement."
        }
        return "The app has a window and published no state, so it may have launched without "
            + "\(UITestLaunchArgument.deterministicWindow)."
    }

    /// Opens Activity through the in-content link, which is the route Interval 9 made reliable.
    @MainActor
    private func openActivity(in app: XCUIApplication) {
        let link = app.descendants(matching: .any)["dashboard.activityLink"]
        XCTAssertTrue(link.waitForExistence(timeout: Self.elementTimeout), "The dashboard should offer a way into Activity")
        clickWhenReady(link, in: app, "The dashboard's Activity link")
        XCTAssertTrue(app.descendants(matching: .any)["activity.screen"].waitForExistence(timeout: Self.elementTimeout))
    }

    /// Clicks an element once it is not merely present but actually able to act on the click.
    ///
    /// ### Three states, not one, and the third is what this interval added
    ///
    /// `waitForExistence` answers the wrong question. An element can exist in the tree while a
    /// sheet is still animating in, and a click that lands on it then is accepted and does
    /// nothing. Interval 10 fixed that half by waiting for `isHittable`.
    ///
    /// `isHittable` is also not the whole question, and the other half is what was still failing.
    /// Hittability is geometric: it asks whether a click would land on this element, not whether
    /// the element would do anything with it. **A disabled SwiftUI button exists and is
    /// hittable.** `dashboard.previewCleanupButton` is disabled until a sender is selected, and
    /// measured on this machine that is exactly how one of the intermittent failures happens:
    ///
    /// ```
    /// t =  8.53s Click "The Daily Digest" StaticText
    /// t = 11.31s Checking `Expect predicate `isHittable == 1` … "dashboard.previewCleanupButton"`
    /// t = 11.52s Click "dashboard.previewCleanupButton" Button
    /// t = 12.21s Waiting 20.0s for "cleanupPlan.screen" Any to exist   ← never appears
    /// ```
    ///
    /// The preview button was hittable and disabled, because the selection from the click three
    /// seconds earlier had not reached it. The click was swallowed, and the case failed twenty
    /// seconds later on an assertion about a sheet, naming a screen that was never going to open.
    ///
    /// So the wait is now for `isHittable && isEnabled`, which is the real precondition for a
    /// click to mean anything. This is a **stronger** assertion than before, not a looser one:
    /// nothing is retried, nothing is slept on, no timeout grew, and an element that never
    /// becomes clickable still fails the case here, naming itself.
    @MainActor
    @discardableResult
    private func clickWhenReady(
        _ element: XCUIElement,
        in app: XCUIApplication,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        front(app)
        guard element.waitForExistence(timeout: Self.elementTimeout) else {
            XCTFail("\(description) never appeared", file: file, line: line)
            return false
        }

        // `exists` is part of the predicate, not merely a precondition. An element can leave the
        // tree between the wait above and this one, and a predicate that then asked only about
        // hittability would raise rather than fail.
        let clickable = expectation(
            for: NSPredicate(format: "exists == true AND isHittable == true AND isEnabled == true"),
            evaluatedWith: element
        )
        guard XCTWaiter.wait(for: [clickable], timeout: Self.elementTimeout) == .completed else {
            XCTFail("\(description) appeared but never became clickable: \(state(of: element))", file: file, line: line)
            return false
        }

        front(app)
        element.click()
        return true
    }

    /// Puts the app under test in front, immediately before something is done to it.
    ///
    /// ### Why a click needs this even with a full-screen Space
    ///
    /// Because XCUITest checks for *interrupting elements* before it synthesizes a click, and if
    /// it finds any it runs a fixed sequence of built-in interruption handlers that cannot be
    /// switched off. Measured, on the run that prompted this:
    ///
    /// ```
    /// t = 14.06s Found 4 interrupting elements:
    ///     Dialog  from 'com.microsoft.teams2'
    ///     Window  from 'com.anthropic.claudefordesktop'
    ///     Window  from 'com.brave.Browser'
    ///     Window  from 'com.apple.finder'
    /// …
    /// t = 89.41s Open quang.InboxSweep → Activate
    /// t = 90.04s Synthesize event
    /// ```
    ///
    /// Seventy-five seconds between the click being asked for and the click happening, spent
    /// asking four other applications' windows whether they were a Bluetooth setup assistant. The
    /// case then failed twenty seconds later on an assertion about a screen, and the screen was
    /// never the problem. That is the shape of most of this suite's residual flakiness, and it is
    /// why the timeouts kept being raised: they were absorbing an interruption pass rather than
    /// waiting for the app.
    ///
    /// The Interval 9 note says `XCUIApplication.activate()` was tried and did not help. It was
    /// tried as a *replacement* for the full-screen Space, and as one it does nothing. Alongside
    /// it, it does the one thing the Space cannot do for itself: when macOS has switched away to
    /// some other application's desktop, activating brings its Space back, so the runner's check
    /// finds nothing to be interrupted by and the click goes out at once.
    ///
    /// Cheap, idempotent, and not a retry: it does not re-attempt a failed interaction, does not
    /// loop, and does not wait. It makes the state the click is synthesized in deterministic.
    @MainActor
    private func front(_ app: XCUIApplication) {
        app.activate()
    }

    /// Describes why an element could not be clicked, without asking it anything that would raise.
    ///
    /// Reading `isHittable` or `isEnabled` on an element that has left the accessibility tree
    /// raises, and raising *inside the failure message* replaces a diagnosis with a snapshot
    /// error. It happened: a case that should have said the unsubscribe review button never
    /// became clickable reported `Failed to get matching snapshot` instead, because by the time
    /// the message was assembled the sheet had gone.
    @MainActor
    private func state(of element: XCUIElement) -> String {
        guard element.exists else {
            return "it is no longer in the app's accessibility tree, which usually means the "
                + "screen it was on closed or the app lost the foreground"
        }
        return "hittable: \(element.isHittable), enabled: \(element.isEnabled)"
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
        XCTAssertTrue(table.waitForExistence(timeout: Self.dashboardLoadTimeout))

        clickWhenReady(senderRow(named: sender, in: app), in: app, "The sender row for \(sender)")

        clickWhenReady(app.buttons["dashboard.previewCleanupButton"], in: app, "The Preview cleanup button")
        XCTAssertTrue(app.descendants(matching: .any)["cleanupPlan.screen"].waitForExistence(timeout: Self.elementTimeout))

        // Queried across all element types: a link-styled button reports itself as a link.
        clickWhenReady(
            app.descendants(matching: .any)["cleanupPlan.reviewButton"].firstMatch,
            in: app,
            "The preview's message-review link"
        )

        XCTAssertTrue(
            app.descendants(matching: .any)["messageReview.screen"].waitForExistence(timeout: Self.elementTimeout),
            "The message review should open for \(sender)"
        )
    }

    /// Opens one sender's unsubscribe options from the message review.
    @MainActor
    private func openUnsubscribeOptions(for sender: String, in app: XCUIApplication) {
        openMessageReview(for: sender, in: app)

        XCTAssertTrue(
            app.buttons["messageReview.unsubscribeButton"].waitForExistence(timeout: Self.elementTimeout),
            "A sender whose headers mention unsubscribing should offer to show the options"
        )
        clickWhenReady(app.buttons["messageReview.unsubscribeButton"], in: app, "The Unsubscribe… button")

        XCTAssertTrue(
            app.descendants(matching: .any)["unsubscribeOptions.screen"].waitForExistence(timeout: Self.elementTimeout),
            "The unsubscribe options should open"
        )
    }

    /// Closes the unsubscribe options and the message review behind it.
    @MainActor
    private func closeUnsubscribeOptions(in app: XCUIApplication) {
        clickWhenReady(app.descendants(matching: .any)["unsubscribeOptions.doneButton"].firstMatch, in: app, "The unsubscribe options Done button")
        XCTAssertTrue(app.descendants(matching: .any)["messageReview.screen"].waitForExistence(timeout: Self.elementTimeout))
        clickWhenReady(app.descendants(matching: .any)["messageReview.doneButton"].firstMatch, in: app, "The message review Done button")
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
        waitForDeterministicWindow(app)

        XCTAssertTrue(
            app.staticTexts["signedOut.title"].waitForExistence(timeout: Self.elementTimeout),
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
        XCTAssertTrue(table.waitForExistence(timeout: Self.dashboardLoadTimeout), "The dashboard should load from sample data")

        XCTAssertTrue(app.descendants(matching: .any)["dashboard.metrics"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["dashboard.accountLabel"].exists,
            "The dashboard should name the connected account"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["The Daily Digest"].waitForExistence(timeout: Self.elementTimeout),
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
        XCTAssertTrue(table.waitForExistence(timeout: Self.dashboardLoadTimeout), "The dashboard should load from sample data")

        XCTAssertTrue(
            app.descendants(matching: .any)["dashboard.filterPicker"].exists,
            "The dashboard should offer proposal filters"
        )

        let previewButton = app.buttons["dashboard.previewCleanupButton"]
        XCTAssertTrue(previewButton.exists)
        XCTAssertFalse(previewButton.isEnabled, "Previewing needs a selection first")

        let sender = senderRow(named: "Storefront Deals", in: app)
        XCTAssertTrue(sender.waitForExistence(timeout: Self.elementTimeout))
        clickWhenReady(sender, in: app, "The sender row for Storefront Deals")

        XCTAssertTrue(
            app.descendants(matching: .any)["senderDetail.proposal"].waitForExistence(timeout: Self.elementTimeout),
            "Selecting a sender should show the reasoning behind its proposal"
        )
        XCTAssertTrue(previewButton.isEnabled, "A selected sender can be previewed")

        clickWhenReady(previewButton, in: app, "The Preview cleanup button")

        XCTAssertTrue(
            app.descendants(matching: .any)["cleanupPlan.screen"].waitForExistence(timeout: Self.elementTimeout),
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
        clickWhenReady(app.buttons["cleanupPlan.doneButton"], in: app, "The preview's Done button")
    }

    /// The Interval 4 path: the dashboard states how much mail it has analysed, and offers the
    /// controls that change it.
    ///
    /// Driven through the real UI because coverage is the claim most easily overstated: a
    /// dashboard that quietly implied it had read the whole mailbox would mislead the user at
    /// exactly the moment they are weighing a suggestion.
    @MainActor
    func testDashboardStatesHowMuchMailHasBeenAnalysed() {
        let app = launchSampleApp()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: Self.dashboardLoadTimeout), "The dashboard should load from sample data")

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
    /// runner: a toolbar is a place a control can be hard to get at, collapsed into an overflow
    /// menu on a narrow window and unreachable to anything driving the app from outside, and
    /// "what has this app changed?" deserves an answer that does not depend on one. The journey
    /// behind both is identical, so testing the reachable one covers the behaviour rather than
    /// proving XCUITest can press a macOS toolbar button.
    @MainActor
    func testActivityIsReachableFromTheContentAndCannotChangeAnything() {
        let app = launchSampleApp()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: Self.dashboardLoadTimeout), "The dashboard should load from sample data")

        // Both routes exist. Only one of them is driven.
        XCTAssertTrue(
            app.buttons["dashboard.activityButton"].exists,
            "The toolbar route into Activity should still be there"
        )

        let activityLink = app.descendants(matching: .any)["dashboard.activityLink"]
        XCTAssertTrue(
            activityLink.waitForExistence(timeout: Self.elementTimeout),
            "The dashboard content should offer a way into Activity"
        )
        clickWhenReady(activityLink, in: app, "The dashboard's Activity link")

        XCTAssertTrue(
            app.descendants(matching: .any)["activity.screen"].waitForExistence(timeout: Self.elementTimeout),
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
            app.descendants(matching: .any)["activity.empty"].waitForExistence(timeout: Self.elementTimeout),
            "A session that has changed nothing should show the empty state"
        )

        // Nothing on the screen can reach a mailbox, and the undo is absent rather than disabled.
        XCTAssertFalse(app.buttons["activity.undoButton"].exists)
        XCTAssertFalse(app.buttons["Archive"].exists)
        XCTAssertFalse(app.buttons["Delete"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["archiveSheet.screen"].exists)

        clickWhenReady(app.descendants(matching: .any)["activity.doneButton"].firstMatch, in: app, "Activity's Done button")
        XCTAssertTrue(table.waitForExistence(timeout: Self.elementTimeout), "Closing Activity should return to the dashboard")
    }

    /// Activity with something in it: the rows render, a row opens, and none of it is actionable.
    ///
    /// ### Why the history is seeded rather than performed
    ///
    /// It cannot be performed here. The synthetic mailbox vends no mutation boundary, so a sample
    /// run has nothing that could produce a transaction, which is the right design and is what
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
        waitForDeterministicWindow(app)

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: Self.dashboardLoadTimeout), "The dashboard should load from sample data")

        let activityLink = app.descendants(matching: .any)["dashboard.activityLink"]
        XCTAssertTrue(activityLink.waitForExistence(timeout: Self.elementTimeout))
        clickWhenReady(activityLink, in: app, "The dashboard's Activity link")

        XCTAssertTrue(
            app.descendants(matching: .any)["activity.screen"].waitForExistence(timeout: Self.elementTimeout),
            "The in-content route should open Activity"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["activity.list"].waitForExistence(timeout: Self.elementTimeout),
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
        clickWhenReady(rows.element(boundBy: 0), in: app, "The newest Activity row")

        XCTAssertTrue(
            app.descendants(matching: .any)["activity.detail.tallies"].waitForExistence(timeout: Self.elementTimeout),
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

        clickWhenReady(app.descendants(matching: .any)["activity.doneButton"].firstMatch, in: app, "Activity's Done button")
    }

    /// The sender-level entry point: it exists, it opens a review, and it archives nothing.
    ///
    /// The wording is asserted as well as the navigation. **Review messages to archive…** is the
    /// promise the interval makes: that pressing it moves you into a review rather than carrying
    /// something out, and a later rename to *Archive sender* would be a different product.
    @MainActor
    func testSenderCleanupOpensAReviewRatherThanArchiving() {
        let app = launchSampleApp()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: Self.dashboardLoadTimeout))

        let sender = senderRow(named: "Storefront Deals", in: app)
        XCTAssertTrue(sender.waitForExistence(timeout: Self.elementTimeout))
        clickWhenReady(sender, in: app, "The sender row for Storefront Deals")

        let previewButton = app.buttons["dashboard.previewCleanupButton"]
        XCTAssertTrue(previewButton.waitForExistence(timeout: Self.elementTimeout))
        clickWhenReady(previewButton, in: app, "The Preview cleanup button")
        XCTAssertTrue(app.descendants(matching: .any)["cleanupPlan.screen"].waitForExistence(timeout: Self.elementTimeout))

        // Queried across all element types: a link-styled button reports itself as a link.
        let cleanupReview = app.descendants(matching: .any)["cleanupPlan.reviewCleanupButton"]
        XCTAssertTrue(
            cleanupReview.waitForExistence(timeout: Self.elementTimeout),
            "A sender's preview row should offer a way to review the messages it names"
        )
        clickWhenReady(cleanupReview, in: app, "The preview's sender-cleanup review link")

        XCTAssertTrue(
            app.descendants(matching: .any)["messageReview.screen"].waitForExistence(timeout: Self.elementTimeout),
            "The sender-level action should open the message review"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["messageReview.preselectionSummary"].waitForExistence(timeout: Self.elementTimeout),
            "The review should say what it preselected, or why it preselected nothing"
        )

        // The whole point of the interval: the convenience got the user to a review, and stopped.
        // On the synthetic mailbox there is no archiver at all, so the Archive control is absent
        // rather than disabled, which is the app's guarantee that a sample run cannot reach a
        // write even by accident.
        XCTAssertFalse(app.descendants(matching: .any)["archiveSheet.screen"].exists)
        XCTAssertFalse(app.buttons["messageReview.archiveButton"].exists)
        XCTAssertFalse(app.buttons["Archive sender"].exists)
        XCTAssertFalse(app.buttons["Clean sender"].exists)
        XCTAssertFalse(app.buttons["Apply recommendation"].exists)
        XCTAssertFalse(app.buttons["Archive all from sender"].exists)

        clickWhenReady(app.descendants(matching: .any)["messageReview.doneButton"].firstMatch, in: app, "The message review Done button")
    }

    /// Opening the messages behind a sender's proposal, which is what makes a count checkable.
    @MainActor
    func testSenderMessagesCanBeReviewed() {
        let app = launchSampleApp()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: Self.dashboardLoadTimeout))

        let sender = senderRow(named: "Storefront Deals", in: app)
        XCTAssertTrue(sender.waitForExistence(timeout: Self.elementTimeout))
        clickWhenReady(sender, in: app, "The sender row for Storefront Deals")

        // Reached from the preview rather than from the inspector: the inspector's own entry
        // point sits below a long reasoning list and is not reliably on screen at the window
        // size the runner picks. Both open the same review.
        let previewButton = app.buttons["dashboard.previewCleanupButton"]
        XCTAssertTrue(previewButton.waitForExistence(timeout: Self.elementTimeout))
        clickWhenReady(previewButton, in: app, "The Preview cleanup button")

        XCTAssertTrue(app.descendants(matching: .any)["cleanupPlan.screen"].waitForExistence(timeout: Self.elementTimeout))

        // Queried across all element types: a link-styled button reports itself as a link.
        let reviewButton = app.descendants(matching: .any)["cleanupPlan.reviewButton"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: Self.elementTimeout), "The preview should offer a message review")
        clickWhenReady(reviewButton, in: app, "The preview's message-review link")

        XCTAssertTrue(
            app.descendants(matching: .any)["messageReview.screen"].waitForExistence(timeout: Self.elementTimeout),
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
        // that used to live here (no button called "Unsubscribe") became the wrong claim. The
        // right one is narrower and stronger: the control that *opens a reading* may be here,
        // and nothing that acts is. No confirmation sheet, and no verb that would perform one.
        XCTAssertFalse(app.descendants(matching: .any)["unsubscribeSheet.screen"].exists)
        XCTAssertFalse(app.buttons["Send the request"].exists)
        XCTAssertFalse(app.buttons["Stop all mail"].exists)
        XCTAssertFalse(app.buttons["Block sender"].exists)
        XCTAssertFalse(app.buttons["Unsubscribe from sender"].exists)

        clickWhenReady(app.descendants(matching: .any)["messageReview.doneButton"].firstMatch, in: app, "The message review Done button")
    }

    // MARK: - Unsubscribe

    /// A sender whose mail says nothing about unsubscribing offers nothing, and says why.
    @MainActor
    func testSenderWithNoUnsubscribeOptionSaysSo() {
        let app = launchSampleApp()

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: Self.dashboardLoadTimeout))

        // `alerts@example.org` carries no List-Unsubscribe header at all in the synthetic
        // mailbox, which is the "no evidence" state.
        openMessageReview(for: "alerts@example.org", in: app)

        XCTAssertFalse(
            app.buttons["messageReview.unsubscribeButton"].exists,
            "A sender with no unsubscribe metadata should offer no unsubscribe entry point at all"
        )
        XCTAssertFalse(app.descendants(matching: .any)["messageReview.unsubscribeDistinctionNote"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["unsubscribeOptions.screen"].exists)

        clickWhenReady(app.descendants(matching: .any)["messageReview.doneButton"].firstMatch, in: app, "The message review Done button")
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

        clickWhenReady(
            app.descendants(matching: .any)["unsubscribeOptions.reviewButton"],
            in: app,
            "The Review unsubscribe… button"
        )

        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.screen"].waitForExistence(timeout: Self.elementTimeout))

        // The three things this screen exists to say, before anything can happen.
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.destination"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.destinationHost"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.futureMailNote"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.evidence"].exists)

        // The first press opens a second, dedicated confirmation rather than acting.
        clickWhenReady(app.buttons["unsubscribeSheet.actionButton"], in: app, "The unsubscribe action button")

        XCTAssertTrue(
            app.descendants(matching: .any)["unsubscribeSheet.confirmPrompt"].waitForExistence(timeout: Self.elementTimeout),
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
        clickWhenReady(
            app.descendants(matching: .any)["unsubscribeOptions.reviewButton"].firstMatch,
            in: app,
            "The Review unsubscribe… button"
        )
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.screen"].waitForExistence(timeout: Self.elementTimeout))

        clickWhenReady(app.buttons["unsubscribeSheet.actionButton"], in: app, "The unsubscribe action button")
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.confirmPrompt"].waitForExistence(timeout: Self.elementTimeout))

        // "Not now" backs out of the confirmation without acting.
        clickWhenReady(app.buttons["unsubscribeSheet.cancelButton"], in: app, "The confirmation's Not now button")
        XCTAssertFalse(app.descendants(matching: .any)["unsubscribeSheet.outcome"].exists)

        // And "Cancel" closes the sheet.
        clickWhenReady(app.buttons["unsubscribeSheet.cancelButton"], in: app, "The unsubscribe review's Cancel button")
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeOptions.screen"].waitForExistence(timeout: Self.elementTimeout))
        closeUnsubscribeOptions(in: app)

        // Nothing reached Activity, because nothing was performed.
        openActivity(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["activity.empty"].waitForExistence(timeout: Self.elementTimeout),
            "Opening and cancelling a review must leave no Activity entry"
        )
    }

    /// A confirmed one-click, against the in-process endpoint, and the Activity row it leaves.
    @MainActor
    func testConfirmedOneClickUnsubscribeIsRecordedCautiously() {
        let app = launchSampleApp(extraArguments: [UITestLaunchArgument.sampleUnsubscribe])

        openUnsubscribeOptions(for: "The Daily Digest", in: app)
        clickWhenReady(
            app.descendants(matching: .any)["unsubscribeOptions.reviewButton"].firstMatch,
            in: app,
            "The Review unsubscribe… button"
        )
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.screen"].waitForExistence(timeout: Self.elementTimeout))

        clickWhenReady(app.buttons["unsubscribeSheet.actionButton"], in: app, "The unsubscribe action button")
        clickWhenReady(app.buttons["unsubscribeSheet.confirmButton"], in: app, "The unsubscribe confirmation button")

        XCTAssertTrue(
            app.descendants(matching: .any)["unsubscribeSheet.outcome"].waitForExistence(timeout: Self.elementTimeout),
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

        clickWhenReady(app.buttons["unsubscribeSheet.doneButton"], in: app, "The unsubscribe result's Done button")
        closeUnsubscribeOptions(in: app)

        openActivity(in: app)
        let row = app.descendants(matching: .any)["activity.unsubscribeRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.elementTimeout), "The unsubscribe should appear in Activity")
        clickWhenReady(row, in: app, "The unsubscribe row in Activity")

        XCTAssertTrue(app.descendants(matching: .any)["activity.unsubscribeDetail"].waitForExistence(timeout: Self.elementTimeout))
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
        clickWhenReady(
            app.descendants(matching: .any)["unsubscribeOptions.reviewButton"].firstMatch,
            in: app,
            "The Review unsubscribe… button"
        )
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.screen"].waitForExistence(timeout: Self.elementTimeout))

        XCTAssertTrue(app.staticTexts["Unsubscribe page"].exists, "A plain https URL is a page, not a one-click endpoint")
        XCTAssertTrue(app.staticTexts["Your browser opens the page"].exists)
        XCTAssertTrue(app.buttons["unsubscribeSheet.actionButton"].exists)

        // The alternatives sit at the bottom of a scrolling sheet, below the evidence. This used
        // to swipe up first, and the swipe was both unnecessary and a source of failures: the
        // sheet's content is a plain `VStack` inside a `ScrollView`, not a lazy one, so every row
        // is in the accessibility tree whether or not it is scrolled into view, and the swipe
        // went to `app.scrollViews.firstMatch`, which with two sheets on screen is not
        // necessarily this sheet's. Asserting existence is what this case actually claims, and it
        // claims it without depending on where the runner left the scroll position.
        XCTAssertTrue(
            app.descendants(matching: .any)["unsubscribeSheet.alternatives"].waitForExistence(timeout: Self.elementTimeout),
            "A sender offering more than one mechanism must show the others rather than choosing silently"
        )
        clickWhenReady(app.buttons["unsubscribeSheet.cancelButton"], in: app, "The unsubscribe review's Cancel button")
        closeUnsubscribeOptions(in: app)
    }

    /// A mail-only sender says the message is prepared, not sent.
    @MainActor
    func testMailHandoffSaysItWillNotSend() {
        let app = launchSampleApp(extraArguments: [UITestLaunchArgument.sampleUnsubscribe])

        openUnsubscribeOptions(for: "Frontend Weekly", in: app)
        clickWhenReady(
            app.descendants(matching: .any)["unsubscribeOptions.reviewButton"].firstMatch,
            in: app,
            "The Review unsubscribe… button"
        )
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.screen"].waitForExistence(timeout: Self.elementTimeout))

        XCTAssertTrue(app.staticTexts["Email unsubscribe"].exists)
        XCTAssertTrue(app.staticTexts["Your mail app opens a message"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.whatHappens"].exists)
        clickWhenReady(app.buttons["unsubscribeSheet.cancelButton"], in: app, "The unsubscribe review's Cancel button")
        closeUnsubscribeOptions(in: app)
    }

    /// Metadata the parser refused explains itself and offers nothing to press.
    @MainActor
    func testMalformedMetadataCannotBeActedOn() {
        let app = launchSampleApp(extraArguments: [UITestLaunchArgument.sampleUnsubscribe])

        // The Café Bulletin's synthetic header holds an http link and an unbracketed value.
        openUnsubscribeOptions(for: "Café Bulletin", in: app)

        XCTAssertTrue(
            app.descendants(matching: .any)["unsubscribeOptions.unavailable"].waitForExistence(timeout: Self.elementTimeout),
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

        // The review can be opened (it performs nothing) but the request cannot be sent.
        clickWhenReady(
            app.descendants(matching: .any)["unsubscribeOptions.reviewButton"].firstMatch,
            in: app,
            "The Review unsubscribe… button"
        )
        XCTAssertTrue(app.descendants(matching: .any)["unsubscribeSheet.screen"].waitForExistence(timeout: Self.elementTimeout))
        XCTAssertFalse(
            app.buttons["unsubscribeSheet.actionButton"].isEnabled,
            "A session with no unsubscribe boundary must not be able to send a one-click request"
        )
        clickWhenReady(app.buttons["unsubscribeSheet.cancelButton"], in: app, "The unsubscribe review's Cancel button")
        closeUnsubscribeOptions(in: app)
    }

    // MARK: - Rules

    /// The affordance exists, it opens a review, and the review creates nothing.
    ///
    /// The central claim of the interval, driven through the real UI: InboxSweep may suggest that
    /// a rule could be useful, and only the user may create one. A button that quietly created
    /// something would be the whole feature going wrong, and it would go wrong silently.
    @MainActor
    func testCreatingARuleNeedsAReviewAndAConfirmation() {
        let app = launchSampleApp()

        openMessageReview(for: "Storefront Deals", in: app)

        clickWhenReady(app.buttons["messageReview.createRuleButton"], in: app, "The Create archive rule… button")
        XCTAssertTrue(
            app.descendants(matching: .any)["ruleReview.screen"].waitForExistence(timeout: Self.elementTimeout),
            "The rule affordance must open a review"
        )

        // The six things this screen exists to say, before anything can happen.
        XCTAssertTrue(app.descendants(matching: .any)["ruleReview.senderKey"].exists, "The review must print the exact address it matches")
        XCTAssertTrue(app.descendants(matching: .any)["ruleReview.matchingNote"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ruleReview.action"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ruleReview.executionNote"].exists, "The review must say when the rule can run")
        XCTAssertTrue(app.descendants(matching: .any)["ruleReview.existingMailNote"].exists, "The review must say existing mail is untouched")
        XCTAssertTrue(app.descendants(matching: .any)["ruleReview.protectionNote"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ruleReview.revocationNote"].exists, "The review must say how to end the rule")

        // Nothing an unsubscribe would need is on this screen, and nothing that could send one.
        XCTAssertFalse(app.descendants(matching: .any)["unsubscribeSheet.screen"].exists)
        XCTAssertFalse(app.buttons["Unsubscribe"].exists)
        XCTAssertFalse(app.buttons["Send the request"].exists)
        XCTAssertFalse(app.buttons["Delete"].exists)
        XCTAssertFalse(app.buttons["Trash"].exists)

        // The first press opens a second, dedicated confirmation rather than creating anything.
        clickWhenReady(app.buttons["ruleReview.actionButton"], in: app, "The Create rule… button")
        XCTAssertTrue(
            app.descendants(matching: .any)["ruleReview.confirmPrompt"].waitForExistence(timeout: Self.elementTimeout),
            "Creating must be gated behind a dedicated confirmation"
        )
        XCTAssertFalse(app.descendants(matching: .any)["ruleReview.created"].exists, "Nothing may have been created yet")

        // Backing out of the confirmation, and then out of the sheet, leaves nothing behind.
        clickWhenReady(app.buttons["ruleReview.cancelButton"], in: app, "The Not now button")
        clickWhenReady(app.buttons["ruleReview.cancelButton"], in: app, "The review's Cancel button")
        XCTAssertTrue(app.descendants(matching: .any)["messageReview.screen"].waitForExistence(timeout: Self.elementTimeout))

        // And the affordance is still the one that offers to create, not one that reports a rule.
        XCTAssertTrue(app.buttons["messageReview.createRuleButton"].exists)
        XCTAssertFalse(app.buttons["messageReview.existingRuleButton"].exists)

        clickWhenReady(app.descendants(matching: .any)["messageReview.doneButton"].firstMatch, in: app, "The message review Done button")

        // Nothing reached the rules list either.
        clickWhenReady(app.descendants(matching: .any)["dashboard.rulesLink"], in: app, "The dashboard's Rules link")
        XCTAssertTrue(app.descendants(matching: .any)["rules.screen"].waitForExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(
            app.descendants(matching: .any)["rules.empty"].waitForExistence(timeout: Self.elementTimeout),
            "Opening and cancelling a rule review must leave no rule"
        )
    }

    /// Confirming creates exactly one rule, and it is listed, inspectable, and reversible.
    @MainActor
    func testConfirmedRuleIsCreatedAndManageable() {
        let app = launchSampleApp(extraArguments: [UITestLaunchArgument.sampleArchiving])

        openMessageReview(for: "Storefront Deals", in: app)
        clickWhenReady(app.buttons["messageReview.createRuleButton"], in: app, "The Create archive rule… button")
        XCTAssertTrue(app.descendants(matching: .any)["ruleReview.screen"].waitForExistence(timeout: Self.elementTimeout))

        clickWhenReady(app.buttons["ruleReview.actionButton"], in: app, "The Create rule… button")
        clickWhenReady(app.buttons["ruleReview.confirmButton"], in: app, "The Create rule confirmation")

        XCTAssertTrue(
            app.descendants(matching: .any)["ruleReview.created"].waitForExistence(timeout: Self.elementTimeout),
            "The review should report the rule it created"
        )
        clickWhenReady(app.buttons["ruleReview.doneButton"], in: app, "The rule review's Done button")

        // The affordance now points at the rule rather than offering a second one.
        XCTAssertTrue(
            app.buttons["messageReview.existingRuleButton"].waitForExistence(timeout: Self.elementTimeout),
            "A sender that already has a rule must not be offered another"
        )
        XCTAssertFalse(app.buttons["messageReview.createRuleButton"].exists)

        clickWhenReady(app.descendants(matching: .any)["messageReview.doneButton"].firstMatch, in: app, "The message review Done button")

        clickWhenReady(app.descendants(matching: .any)["dashboard.rulesLink"], in: app, "The dashboard's Rules link")
        XCTAssertTrue(app.descendants(matching: .any)["rules.screen"].waitForExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(app.descendants(matching: .any)["rules.list"].waitForExistence(timeout: Self.elementTimeout))
        XCTAssertFalse(app.descendants(matching: .any)["rules.empty"].exists)

        // The row says what it matches, what it does, and when it can run.
        XCTAssertTrue(app.descendants(matching: .any)["rules.row.senderKey"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["rules.row.action"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["rules.row.executionNote"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["rules.boundaryNote"].exists)

        // Turning it off takes one press and no confirmation, because it is the safe direction.
        let toggle = app.descendants(matching: .any)["rules.row.enabledToggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: Self.elementTimeout))
        clickWhenReady(toggle, in: app, "The rule's enabled toggle")

        // Deleting takes a confirmation, because it throws away a decision.
        clickWhenReady(
            app.descendants(matching: .any)["rules.row.deleteButton"].firstMatch,
            in: app,
            "The rule's Delete button"
        )
        clickWhenReady(app.buttons["rules.confirmDeleteButton"], in: app, "The delete confirmation")
        XCTAssertTrue(
            app.descendants(matching: .any)["rules.empty"].waitForExistence(timeout: Self.elementTimeout),
            "Deleting the only rule should leave the empty state"
        )
    }

    /// A rule that runs: what it archived, what it refused, and the undo it does not claim.
    ///
    /// Driven with both sample boundaries, so the whole pass happens in-process: a seeded rule, an
    /// archiver with no transport, and a synthetic mailbox. Nothing leaves the machine.
    @MainActor
    func testARuleReportsWhatItDidAndOffersNoUndo() {
        let app = launchSampleApp(extraArguments: [
            UITestLaunchArgument.sampleArchiving,
            UITestLaunchArgument.sampleRules,
        ])

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: Self.dashboardLoadTimeout))

        // The pass ran during the load, and said so where the user is looking.
        XCTAssertTrue(
            app.descendants(matching: .any)["dashboard.ruleRun"].waitForExistence(timeout: Self.elementTimeout),
            "A rule that changed the mailbox must say so on the dashboard"
        )
        XCTAssertTrue(app.descendants(matching: .any)["dashboard.ruleRun.archived"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["dashboard.ruleRun.noUndo"].exists,
            "A rule-driven archive must say there is no undo rather than quietly not offering one"
        )
        XCTAssertFalse(app.buttons["Undo"].exists)

        // Activity attributes it to the rule and still offers nothing to press.
        openActivity(in: app)
        let row = app.descendants(matching: .any)["activity.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.elementTimeout), "The rule's archive should appear in Activity")
        XCTAssertTrue(
            app.descendants(matching: .any)["activity.row.ruleAttribution"].firstMatch.exists,
            "An Activity row must name the rule that produced it"
        )
        clickWhenReady(row, in: app, "The newest Activity row")

        XCTAssertTrue(app.descendants(matching: .any)["activity.detail.tallies"].waitForExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(app.descendants(matching: .any)["activity.detail.ruleAttribution"].exists)
        XCTAssertFalse(app.buttons["activity.undoButton"].exists, "A rule-driven archive is never undoable")

        clickWhenReady(app.descendants(matching: .any)["activity.doneButton"].firstMatch, in: app, "Activity's Done button")
    }

    /// A seeded rule with no boundary behind it is listed, honest, and inert.
    ///
    /// The state a real user reaches with a read-only grant: the authorization is remembered,
    /// because forgetting a decision over today's permissions would be worse, and the app says
    /// plainly that it is not running rather than implying it is.
    @MainActor
    func testARuleWithoutAnArchiveBoundaryIsListedAndInert() {
        let app = launchSampleApp(extraArguments: [UITestLaunchArgument.sampleRules])

        let table = app.descendants(matching: .any)["dashboard.senderTable"]
        XCTAssertTrue(table.waitForExistence(timeout: Self.dashboardLoadTimeout))

        // Nothing ran, so nothing is reported.
        XCTAssertFalse(app.descendants(matching: .any)["dashboard.ruleRun"].exists)

        // The sender the rule names is still on the dashboard, untouched.
        XCTAssertTrue(
            app.descendants(matching: .any)["The Daily Digest"].waitForExistence(timeout: Self.elementTimeout),
            "A rule with no way to run must leave the mailbox exactly as it was"
        )

        clickWhenReady(app.descendants(matching: .any)["dashboard.rulesLink"], in: app, "The dashboard's Rules link")
        XCTAssertTrue(app.descendants(matching: .any)["rules.screen"].waitForExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(app.descendants(matching: .any)["rules.list"].waitForExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(
            app.descendants(matching: .any)["rules.row.executionNote"].firstMatch.exists,
            "A rule that cannot run must say so on its own row"
        )

        clickWhenReady(app.descendants(matching: .any)["rules.doneButton"].firstMatch, in: app, "The Rules Done button")
    }
}

#if DEBUG
import AppKit
import Observation

/// Puts the window under test on a screen of its own, at a known size, in front of everything
/// else, and says out loud whether it got there.
///
/// ### Why this exists
///
/// Two UI cases (the proposal/dry-run journey and the message review) failed for two intervals
/// with `Unable to find hit point for ScrollView`. The cause was not the app. Every case that
/// only *asserted* passed; every case that *clicked* failed, and the runner's own log named the
/// reason:
///
/// ```
/// Found 2 interrupting elements:
///     Window at {{-0.0, 30.0}, {837.0, 920.0}} from Application 'com.anthropic.claudefordesktop'
///     Window at {{839.0, 30.0}, {841.0, 924.0}} from Application 'com.brave.Browser'
/// ```
///
/// Those two cover the whole 1,680-point width of the display. With them on screen, **nothing in
/// InboxSweep is hittable**: measured, not assumed, with a probe that reported `isHittable ==
/// false` for the sender name, for the *Preview cleanup* button, for the filter picker, and for a
/// line of text in the footer. That last one matters, because it rules out the explanation the
/// earlier interval reached for. The toolbar was never the problem; a toolbar button is simply
/// one more control on a window that no click could reach.
///
/// ### What it does about it
///
/// Three things, all about making the *launch state* deterministic rather than about making an
/// assertion pass:
///
/// - **A fixed content size, centred**, so the geometry under test is not a measurement of where
///   the developer last dragged the window.
/// - **Frontmost, above other applications.**
/// - **Full screen**, which is the one that actually works.
///
/// A full-screen macOS window gets a Space of its own. Every other application's windows are on
/// a different Space, so they are not merely below InboxSweep's window in a z-order: they are
/// not on screen at all, there is nothing for the runner to report as interrupting, and the app
/// under test is unambiguously the frontmost application.
///
/// What was tried before and did not work, kept here so it is not tried again: `NSApplication`
/// activation in both its polite and impolite forms, `orderFrontRegardless()` on every window and
/// on every state change, `NSWindow.Level.floating` and `.screenSaver` (measured: level changes
/// nothing, because the runner's hit test resolves through the frontmost *application* rather
/// than through which window is drawn on top), `XCUIApplication.activate()` from the runner, and
/// clicking a table row rather than the sender's name.
///
/// ### Why Interval 11 rewrote it
///
/// The Interval 9 version applied the geometry **once**, on the first `onAppear`, and then
/// assumed it had worked. It had no way to know, and one measured run of the suite shows that it
/// does not always work. In `testConfirmedOneClickUnsubscribeIsRecordedCautiously`, launched
/// immediately after a case that had itself timed out, the sender table existed at t=6.7s, the
/// sender's name took a further twenty seconds to appear, and then reported `isHittable == false`
/// for the next twenty until the case failed. That is the Interval 9 symptom exactly, in a suite
/// that had supposedly fixed it, and the difference is timing: terminating an app that owns a
/// full-screen Space destroys that Space, and a `toggleFullScreen(_:)` issued while macOS is
/// still tearing the old one down is dropped silently. The window then stays on the shared Space
/// with the developer's other windows over it, and every control in the app is unreachable for
/// the life of that case.
///
/// So the placement is now a small state machine rather than a single statement:
///
/// - it re-asserts the request, bounded, until the window reports `styleMask.contains(.fullScreen)`
///   rather than until a timer expires;
/// - it treats the full-screen notifications as the signal that the transition finished, rather
///   than assuming the call was synchronous;
/// - it publishes ``phase``, which ``RootView`` renders as a hidden accessibility element, so a
///   failing case says *the window never became deterministic* instead of blaming whichever
///   control the test happened to reach for next.
///
/// It is `#if DEBUG`, gated behind an explicit launch argument, and touches nothing but window
/// geometry, activation, and full-screen state: no provider, no credential store, no view state.
/// A Release build does not contain it; a Debug build launched without the argument does not run
/// it.
///
/// It papers over nothing. A control that is genuinely unreachable, behind a sheet or below a
/// scroll view's fold, still is, and the case still fails. All this removes from the test is the
/// rest of the desktop.
@MainActor
@Observable
final class UITestWindow {

    /// Launch argument that asks for the deterministic window.
    ///
    /// The test side of this string is `UITestLaunchArgument` in the UI test target, which cannot
    /// import this one: a UI test drives the app from outside its process.
    nonisolated static let launchArgument = "--ui-test-window"

    /// The accessibility identifier ``RootView`` publishes the current phase under.
    ///
    /// Present for the whole launch under the argument, with its label carrying
    /// ``Phase/rawValue``, so a test can tell "the app never launched" from "the app launched and
    /// its window never became deterministic". The test side of this string is
    /// `UITestLaunchArgument.windowStateIdentifier`.
    nonisolated static let stateIdentifier = "uiTest.windowState"

    /// Large enough for the dashboard's six columns and the widest sheet the app presents
    /// (``SenderMessageReviewView`` asks for 900) and small enough to sit on one display.
    ///
    /// Applied before the full-screen transition, so a window that cannot go full screen for any
    /// reason still comes up at a size the app's own content fits in.
    nonisolated static let contentSize = NSSize(width: 1_200, height: 760)

    /// How long a full-screen request is given before it is treated as never having arrived.
    ///
    /// This is a backstop on a request macOS *silently discarded*, not a guess at how long a
    /// transition takes. A transition that is merely in progress is never re-requested at all,
    /// because ``isTransitioning`` knows about it from the `willEnterFullScreen` notification and
    /// ``enterFullScreen(_:)`` refuses to touch a window in the middle of one.
    ///
    /// That distinction is the whole of it, and getting it wrong is measurable: a first version of
    /// this retried on the timer alone and re-issued `toggleFullScreen` into a transition that had
    /// simply not finished yet, which queues the opposite transition behind it. The app then
    /// presented **no window** for the life of the case, and the accessibility tree the runner
    /// dumped held a menu bar and nothing else.
    ///
    /// Three seconds is therefore only reached when no transition ever began. It is not a timeout
    /// on an assertion and not a sleep before one: nothing waits on it when the request lands,
    /// because the notification ends the wait.
    nonisolated static let retryInterval: Duration = .seconds(3)

    /// How many times the request is re-issued before the app gives up and says so.
    ///
    /// Bounded so a Mac that genuinely cannot full-screen the window produces a clear
    /// ``Phase/unavailable`` rather than a case that hangs until the runner's own timeout.
    /// Five attempts across ``retryInterval`` is ten seconds, comfortably inside the window the
    /// suite gives this and far outside anything a working transition needs.
    nonisolated static let maximumAttempts = 5

    /// How often the deterministic state is re-checked once it has been reached.
    ///
    /// Reaching the state is not enough, which is the second thing Interval 11 measured. In
    /// `testConfirmedOneClickUnsubscribeIsRecordedCautiously` the window reported `ready` at
    /// t=6.2s and the case ran normally until t=28.6s, at which point a control that had just
    /// been found existing never became hittable again and had vanished from the accessibility
    /// tree entirely by t=53s. That is what losing the foreground looks like from the runner's
    /// side, and nothing in the Interval 9 harness was watching for it: the placement ran once at
    /// launch and never looked again.
    ///
    /// So the state is now **held** as well as reached. Every half second the window is compared
    /// against ``isDeterministic`` and, only if it has drifted, asked for again. Half a second is
    /// chosen against the suite's own twenty-second element timeout: a foreground lost and
    /// recovered inside a second cannot become a failure, and a check that costs one property
    /// read is not worth spacing out further.
    ///
    /// This is not a sleep in front of an assertion. It runs in the app under test, it asserts
    /// nothing, and on a launch where nothing drifts it performs no work at all beyond the
    /// comparison.
    nonisolated static let maintenanceInterval: Duration = .milliseconds(500)

    static let shared = UITestWindow()

    /// How far the deterministic window has got.
    ///
    /// Read by ``RootView`` and published to the accessibility tree. The only value a test
    /// treats as go is ``Phase/ready``.
    private(set) var phase: Phase = .notRequested

    /// Where the placement has got to, in the order it gets there.
    enum Phase: String, Sendable {

        /// The launch argument was not given. The app is behaving exactly as it does for a user.
        case notRequested

        /// Requested, and the scene has not presented a window yet.
        case waitingForWindow = "waitingForWindow"

        /// A window exists and has been sized, centred, raised, and asked to go full screen.
        case enteringFullScreen

        /// The window is full screen, key, and belongs to the active application. Go.
        case ready

        /// The request was made ``maximumAttempts`` times and the window never went full screen.
        ///
        /// A real state rather than a silent fallback: the suite fails here, naming this, rather
        /// than continuing onto a desktop where nothing is hittable and failing somewhere that
        /// looks like the app's fault.
        case unavailable
    }

    nonisolated static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// The placement attempt, held so a second `onAppear` joins it rather than starting a rival.
    private var placement: Task<Void, Never>?

    private var observers: [any NSObjectProtocol] = []

    private init() {}

    /// Starts (or rejoins) the placement, if the argument was given.
    ///
    /// Idempotent by construction: the first call starts the state machine, every later call
    /// finds ``placement`` already running and returns. That matters because `onAppear` is not a
    /// once-per-launch event, and because the Interval 9 version's `hasPlacedWindow` flag made
    /// "already tried" and "actually worked" the same state.
    static func applyIfRequested() {
        guard isRequested else { return }
        shared.start()
    }

    /// Brings the app in front of every other application again.
    ///
    /// Repeatable, and repeated on purpose. Placing the window once is not enough: a launch, a
    /// connect, and a first page of mail take a few seconds, and whatever else is running takes
    /// the foreground back in the meantime.
    ///
    /// Secondary to the full-screen Space now rather than the mechanism. Kept because it costs
    /// nothing and covers the window between launch and the full-screen transition finishing.
    static func keepFrontmostIfRequested() {
        guard isRequested else { return }
        shared.raise()
    }

    // MARK: - The state machine

    private func start() {
        guard placement == nil else { return }
        observeFullScreenTransitions()
        phase = .waitingForWindow

        placement = Task { [weak self] in
            guard let self else { return }
            guard await reachDeterministicState() else { return }
            await holdDeterministicState()
        }
    }

    /// Asks for the deterministic window until it reports that it is in it, or gives up saying so.
    ///
    /// Bounded by ``maximumAttempts``. Returns whether it got there, so the caller does not start
    /// holding a state that was never reached.
    private func reachDeterministicState() async -> Bool {
        for attempt in 0..<Self.maximumAttempts {
            if placeAndCheck() { return true }

            // Bounded, and only reached when the window is *not* in the state asked for. A
            // transition that works ends this loop on the next pass, because the notification
            // has already flipped the style mask by then.
            _ = attempt
            try? await Task.sleep(for: Self.retryInterval)
            if phase == .ready { return true }
            // A request that produced no `willEnterFullScreen` in all that time was discarded,
            // and the flag guarding against a double toggle would otherwise block every retry.
            clearDiscardedRequest()
        }

        // Checked once more before giving up: the last attempt's transition may have landed
        // while the final wait was running.
        guard !placeAndCheck() else { return true }
        phase = .unavailable
        return false
    }

    /// Keeps the window in the state for the rest of the launch, re-asking only when it drifts.
    ///
    /// Runs until the process ends. It is what makes a foreground stolen halfway through a case a
    /// half-second interruption rather than a failed test, and it is why ``phase`` is a live
    /// reading rather than a record of what happened at launch.
    private func holdDeterministicState() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.maintenanceInterval)
            guard !Task.isCancelled else { return }
            if isDeterministic {
                if phase != .ready { phase = .ready }
            } else {
                clearDiscardedRequest()
                _ = placeAndCheck()
            }
        }
    }

    /// One attempt: size, centre, raise, full-screen, and report whether the window got there.
    ///
    /// It reaches for `NSApplication.windows` rather than for the window behind a backing view.
    /// Going through a backing view is the tidier-looking way to find an `NSWindow` from SwiftUI
    /// and it was tried first; the window it hands back during launch is not the one the scene
    /// ends up presenting, and configuring that one left the app windowless.
    private func placeAndCheck() -> Bool {
        // Nothing is touched while macOS is animating a Space in or out. Resizing, centring,
        // raising, or re-toggling a window mid-transition is how the app ends up with no window
        // at all; see ``retryInterval``.
        guard !isTransitioning else { return false }

        let windows = NSApplication.shared.windows.filter(Self.isPlaceable)
        guard !windows.isEmpty else {
            phase = .waitingForWindow
            return false
        }

        // **Every** candidate window, not one chosen from among them. Picking one was tried and
        // is measurably worse: `keyWindow` and `mainWindow` are both `nil` for part of launch, the
        // visible-window fallback then picks whatever SwiftUI has up at that instant, and
        // configuring that one leaves the app presenting **nothing**. Measured directly, outside
        // the runner: `System Events` reported `0` windows for a launch with this argument and `1`
        // without it. The Interval 9 note warns about exactly this; asking which window is the
        // real one during launch is the part that has no reliable answer.
        //
        // Placing all of them is harmless, because an app of this shape has one window a user can
        // see and the rest ignore the treatment.
        for window in windows {
            // **The single most important line in this file.**
            //
            // SwiftUI autosaves the window's frame into the app's own `NSUserDefaults`, and a
            // window that was full screen when the process ended saves a full-screen frame. The
            // Space that frame belonged to is gone by the next launch, and macOS then brings the
            // app up with **no window at all**: not off-screen, not behind something, absent.
            //
            // Measured, and it is what blocked this suite for an afternoon. Every case failed
            // with the app process alive, its accessibility tree holding a menu bar and nothing
            // else, and `System Events` agreeing there were zero windows. It reproduced with this
            // whole harness disabled, which is what finally ruled the harness out; deleting
            // `quang.InboxSweep` from `defaults` fixed it instantly, and the suite went green.
            //
            // Clearing the autosave name means a launch under this argument neither reads a saved
            // frame nor writes one. An ordinary launch is untouched and still remembers where the
            // user left the window: the poison is only ever produced by the full-screen state
            // this file asks for, so this is exactly where it should be cleaned up.
            window.setFrameAutosaveName("")

            // Only while the window is still on the shared Space. Resizing and centring one that
            // is already full screen is at best a no-op and at worst an exit from the Space this
            // exists to reach.
            if !window.styleMask.contains(.fullScreen) {
                window.setContentSize(Self.contentSize)
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            enterFullScreen(window)
        }
        forceToForeground()

        if isDeterministic {
            phase = .ready
            return true
        }
        if phase != .enteringFullScreen { phase = .enteringFullScreen }
        return false
    }

    /// Whether the window is in the state the suite depends on.
    ///
    /// All three parts are load-bearing. Full screen is what removes the rest of the desktop;
    /// key and active are what make the runner's hit test resolve through this application.
    /// Whether **some** window is in the state the suite depends on, and the app owns the screen.
    ///
    /// "Some", not "the first". The Interval 9 version asked
    /// `windows.first(where: \.canBecomeMain)`, and measured, that is a different window from the
    /// one the user sees often enough to matter: one launch reported `enteringFullScreen` for the
    /// full twenty-five seconds because `first` had picked a window that was never going to go
    /// full screen while the one on screen already had. The placement was fine; the question was
    /// being asked of the wrong object.
    ///
    /// Asking about the window that is *key* fixes that without having to identify the right
    /// window in advance, which is the thing that has no reliable answer during launch. It is
    /// also the right question on its own merits: the key window of the active application is
    /// what the runner's hit test resolves to.
    private var isDeterministic: Bool {
        guard NSRunningApplication.current.isActive else { return false }
        // A sheet is key while it is up, and a sheet is never full screen, so the question has to
        // be asked of the window the sheet is attached to rather than of whatever is key.
        return NSApplication.shared.windows.contains {
            Self.isPlaceable($0) && $0.styleMask.contains(.fullScreen) && ($0.isKeyWindow || $0.attachedSheet != nil)
        }
    }

    /// Whether this is a window the placement may touch.
    ///
    /// **Sheets are excluded, and that exclusion is the whole of one bug.** A sheet is an
    /// `NSWindow` that `canBecomeMain`, so the Interval 9 filter matched it. That was harmless
    /// while the placement ran exactly once, at launch, before any sheet existed. It stopped
    /// being harmless the moment this file grew a loop that holds the state for the life of the
    /// process: every half second it was calling `setContentSize`, `center()`, and
    /// `toggleFullScreen(_:)` on whatever sheet happened to be up.
    ///
    /// Measured. A case that had just asserted six things about the rule review sheet then failed
    /// to find the button in its footer, and the accessibility tree in the failure showed the app
    /// back on the dashboard with no sheet at all. Three cases failed that way, and several
    /// earlier "the element is no longer in the accessibility tree" failures have the same shape.
    ///
    /// `parent` covers child windows generally; `isSheet` covers the case that matters.
    private static func isPlaceable(_ window: NSWindow) -> Bool {
        window.canBecomeMain && !window.isSheet && window.parent == nil
    }

    /// Moves one window onto a Space of its own.
    ///
    /// `fullScreenPrimary` is inserted rather than assumed: a SwiftUI scene's window carries it
    /// by default, and a window without it ignores `toggleFullScreen(_:)` silently. The
    /// `styleMask` check keeps the call idempotent, because toggling a window that is already
    /// full screen would put it back on the shared Space, which is the state this exists to
    /// leave.
    private func enterFullScreen(_ window: NSWindow) {
        window.collectionBehavior.insert(.fullScreenPrimary)
        guard !window.styleMask.contains(.fullScreen), !isTransitioning else { return }
        isTransitioning = true
        requestedFullScreenAt = Date()
        window.toggleFullScreen(nil)
    }

    /// Whether macOS is animating a Space in or out right now.
    ///
    /// Set optimistically when a toggle is issued and authoritatively by the `will` notifications,
    /// cleared by the `did` ones. Optimistically because `toggleFullScreen(_:)` returns before
    /// `willEnterFullScreen` is posted, and the half-millisecond between the two is long enough
    /// for the maintenance loop to issue a second toggle.
    ///
    /// A request macOS discards outright posts no notification at all, which is why this is
    /// cleared by ``retryInterval`` elapsing as well: without that, one silently dropped request
    /// would leave the state machine believing a transition was still running forever.
    private var isTransitioning = false

    /// When the current full-screen request was made, for ``logTransition(_:)``.
    private var requestedFullScreenAt: Date?

    /// Prints how long the transition took, or that one arrived without having been asked for.
    ///
    /// Diagnostics, in a `#if DEBUG` type behind a launch argument, reaching stderr and nothing
    /// else. It is what ``retryInterval`` is calibrated against, and it is what turns "the window
    /// sometimes is not full screen" into a number somebody can argue with. No production code
    /// path can reach it, and it records nothing about mail.
    private func logTransition(_ name: Notification.Name) {
        let elapsed = requestedFullScreenAt.map { Date().timeIntervalSince($0) }
        let phrase = elapsed.map { String(format: "%.3fs after the request", $0) } ?? "unrequested"
        let event = name == NSWindow.didEnterFullScreenNotification ? "entered full screen" : "left full screen"
        FileHandle.standardError.write(Data("[UITestWindow] \(event), \(phrase)\n".utf8))
        if name == NSWindow.didEnterFullScreenNotification { requestedFullScreenAt = nil }
    }

    /// Re-checks readiness whenever macOS says a transition finished.
    ///
    /// The notifications are the honest end of the wait. `toggleFullScreen(_:)` returns long
    /// before the Space exists, so a version that trusted the call would report ready while the
    /// window was still animating, which is the same lie the Interval 9 version told.
    private func observeFullScreenTransitions() {
        guard observers.isEmpty else { return }

        // The foreground going is worth acting on at once rather than at the next maintenance
        // check: everything in the app is unhittable while another application holds it.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    UITestWindow.shared.raise()
                }
            }
        )

        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { _ in
                    MainActor.assumeIsolated { UITestWindow.shared.beginTransition() }
                }
            )
        }

        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        UITestWindow.shared.logTransition(name)
                        UITestWindow.shared.endTransition()
                        UITestWindow.shared.reassess()
                    }
                }
            )
        }
    }

    private func beginTransition() {
        isTransitioning = true
        if phase == .waitingForWindow { phase = .enteringFullScreen }
    }

    private func endTransition() {
        isTransitioning = false
        requestedFullScreenAt = nil
    }

    /// Recomputes ``phase`` after a transition, without starting another attempt.
    private func reassess() {
        guard phase != .notRequested else { return }
        forceToForeground()
        phase = isDeterministic ? .ready : .enteringFullScreen
    }

    /// Lets go of a request that produced no transition, so the next attempt is not blocked.
    ///
    /// Only ever clears a request older than ``retryInterval``, so a transition that is genuinely
    /// under way is left alone. This is the one place a duration is compared against, and it is
    /// comparing against "did macOS ever acknowledge this", not against "is the animation done".
    private func clearDiscardedRequest() {
        guard isTransitioning, let requestedFullScreenAt else { return }
        guard Date().timeIntervalSince(requestedFullScreenAt) >= Self.retryInterval.seconds else { return }
        isTransitioning = false
        self.requestedFullScreenAt = nil
    }

    private func raise() {
        guard phase != .notRequested else { return }
        forceToForeground()
        // Sheets excluded here for the same reason the placement excludes them, and it is the
        // same bug twice: `orderFrontRegardless()` on a sheet orders it independently of the
        // window it is attached to, and a sheet that has been separated from its parent is a
        // sheet that goes away. This runs on every session state change and on every resignation
        // of the foreground, so with a sheet on screen it fired constantly.
        for window in NSApplication.shared.windows where window.isVisible && Self.isPlaceable(window) {
            window.orderFrontRegardless()
        }
        // Reported either way. A ``phase`` that only ever climbed would have told the suite the
        // window was fine at exactly the moment it was not.
        if phase == .ready || phase == .enteringFullScreen {
            phase = isDeterministic ? .ready : .enteringFullScreen
        }
    }

    /// Takes the foreground, rather than asking for it.
    ///
    /// `NSApplication.activate()` is the polite form and honours the system's focus rules, which
    /// is right for an app and wrong for this. `NSRunningApplication.activate(options:)` on the
    /// current process does not ask, though on recent macOS it is refused too when another
    /// application holds the foreground, which is why the full-screen Space is what the suite
    /// actually depends on.
    private func forceToForeground() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}

private extension Duration {
    /// The duration in seconds, for comparing against a `Date` interval.
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
#endif

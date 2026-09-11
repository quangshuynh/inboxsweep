#if DEBUG
import AppKit

/// Puts the window under test at a known size, in a known place, in front of everything else.
///
/// ### Why this exists
///
/// Two UI cases — the proposal/dry-run journey and the message review — failed for an interval
/// with `Unable to find hit point for ScrollView`. The cause was not the app. Every case that
/// only *asserted* passed; every case that *clicked* failed, and the runner's own log named the
/// reason:
///
/// ```
/// Found 2 interrupting elements:
///     Window at {{839.0, 30.0}, {841.0, 927.0}} from Application 'com.brave.Browser'
///     Window at {{0.0, 30.0}, {940.0, 920.0}} from Application 'com.anthropic.claudefordesktop'
/// ```
///
/// The window under test had been left 1,680 points wide, spanning two displays, with other
/// applications' windows over the half that held the sender table. The target row was therefore
/// not hittable; XCUITest fell back to *scrolling it into view*; and that scroll needed a hit
/// point on the table's backing scroll view, which the same windows covered. The error named the
/// scroll view, so it read like a layout bug in InboxSweep. It was not one.
///
/// ### What it does about it
///
/// Two things, both about making the *launch state* deterministic rather than about making an
/// assertion pass:
///
/// - **A fixed content size, centred.** A UI test whose geometry depends on where the developer
///   last dragged the window is not a test, it is a measurement of somebody's desktop.
/// - **Frontmost, above other applications.** So the window under test is the one a hit test
///   lands on.
///
/// It is `#if DEBUG`, gated behind an explicit launch argument, and touches nothing but window
/// geometry and activation — no provider, no credential store, no view state. A Release build
/// does not contain it; a Debug build launched without the argument does not run it.
///
/// It papers over nothing: a control that is genuinely unreachable — off the edge of a 1,200×760
/// window, behind a sheet, below a scroll view's fold — still is, and the case still fails. All
/// this removes from the test is the rest of the desktop.
enum UITestWindow {

    /// Launch argument that asks for the deterministic window.
    ///
    /// The test side of this string is `UITestLaunchArgument` in the UI test target, which cannot
    /// import this one: a UI test drives the app from outside its process.
    static let launchArgument = "--ui-test-window"

    /// Large enough for the dashboard's six columns and the widest sheet the app presents —
    /// ``SenderMessageReviewView`` asks for 900 — and small enough to sit on one display.
    static let contentSize = NSSize(width: 1_200, height: 760)

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Whether the window has already been placed this launch.
    @MainActor private static var hasPlacedWindow = false

    /// Sizes, centres, and raises the app's windows, if the argument was given.
    ///
    /// Applied **once**. Re-running the geometry on every state change was tried and left the
    /// app presenting no window at all while the signed-out screen was still settling.
    ///
    /// It reaches for `NSApplication.windows` rather than for the window behind a backing view.
    /// Going through a backing view is the tidier-looking way to find an `NSWindow` from SwiftUI
    /// and it was tried first; the window it hands back during launch is not the one the scene
    /// ends up presenting, and configuring that one left the app windowless too.
    @MainActor
    static func applyIfRequested() {
        guard isRequested, !hasPlacedWindow else { return }
        hasPlacedWindow = true

        for window in NSApplication.shared.windows {
            window.setContentSize(contentSize)
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        forceToForeground()
    }

    /// Brings the app in front of every other application again.
    ///
    /// Repeatable, and repeated on purpose. Placing the window once is not enough: a launch, a
    /// connect, and a first page of mail take a few seconds, and whatever else is running takes
    /// the foreground back in the meantime — at which point a click in the test lands on
    /// somebody else's window and the runner reports it as an unhittable scroll view.
    ///
    /// **Activation is the mechanism, not window level.** Floating the window above everything
    /// (`NSWindow.Level.floating`) looks like the sturdier fix and was tried; it made things
    /// worse. XCUITest's occlusion check is about which *application* is in front, not about
    /// which window is drawn on top, so the thing that has to be true is that the app under test
    /// is the frontmost application.
    ///
    /// Deliberately only ordering and activation. Re-running `setContentSize` and `center` here
    /// is what left the app windowless.
    @MainActor
    static func keepFrontmostIfRequested() {
        guard isRequested else { return }

        forceToForeground()
        for window in NSApplication.shared.windows where window.isVisible {
            window.orderFrontRegardless()
        }
    }

    /// Takes the foreground, rather than asking for it.
    ///
    /// `NSApplication.activate()` is the polite form and honours the system's focus rules, which
    /// is right for an app and wrong for this: under test the app genuinely does need to be in
    /// front of whatever else is running, and the polite form left it behind another
    /// application's window often enough that clicks landed or missed depending on how long the
    /// case had spent waiting. `NSRunningApplication.activate(options:)` on the current process
    /// does not ask.
    @MainActor
    private static func forceToForeground() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}

#endif

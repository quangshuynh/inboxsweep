#if DEBUG
import AppKit

/// Puts the window under test on a screen of its own, at a known size, in front of everything else.
///
/// ### Why this exists
///
/// Two UI cases — the proposal/dry-run journey and the message review — failed for two intervals
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
/// InboxSweep is hittable** — measured, not assumed: a probe reported `isHittable == false` for
/// the sender name, for the *Preview cleanup* button, for the filter picker, and for a line of
/// text in the footer. That last one matters, because it rules out the explanation the previous
/// interval reached for. The toolbar was never the problem; a toolbar button is simply one more
/// control on a window that no click could reach.
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
/// a different Space, so they are not merely below InboxSweep's window in a z-order — they are
/// not on screen at all, there is nothing for the runner to report as interrupting, and the app
/// under test is unambiguously the frontmost application. With it, the two long-red cases pass
/// and every control in the app is hittable.
///
/// What was tried before and did not work, kept here so it is not tried again: `NSApplication`
/// activation in both its polite and impolite forms, `orderFrontRegardless()` on every window and
/// on every state change, `NSWindow.Level.floating` and `.screenSaver` (measured: level changes
/// nothing, because the runner's hit test resolves through the frontmost *application* rather
/// than through which window is drawn on top), `XCUIApplication.activate()` from the runner, and
/// clicking a table row rather than the sender's name.
///
/// It is `#if DEBUG`, gated behind an explicit launch argument, and touches nothing but window
/// geometry, activation, and full-screen state — no provider, no credential store, no view state.
/// A Release build does not contain it; a Debug build launched without the argument does not run
/// it.
///
/// It papers over nothing: a control that is genuinely unreachable — behind a sheet, below a
/// scroll view's fold — still is, and the case still fails. All this removes from the test is the
/// rest of the desktop.
enum UITestWindow {

    /// Launch argument that asks for the deterministic window.
    ///
    /// The test side of this string is `UITestLaunchArgument` in the UI test target, which cannot
    /// import this one: a UI test drives the app from outside its process.
    static let launchArgument = "--ui-test-window"

    /// Large enough for the dashboard's six columns and the widest sheet the app presents —
    /// ``SenderMessageReviewView`` asks for 900 — and small enough to sit on one display.
    ///
    /// Applied before the full-screen transition, so a window that cannot go full screen for any
    /// reason still comes up at a size the app's own content fits in.
    static let contentSize = NSSize(width: 1_200, height: 760)

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Whether the window has already been placed this launch.
    @MainActor private static var hasPlacedWindow = false

    /// Sizes, centres, raises, and full-screens the app's windows, if the argument was given.
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
            enterFullScreen(window)
        }
        forceToForeground()
    }

    /// Moves one window onto a Space of its own.
    ///
    /// `fullScreenPrimary` is inserted rather than assumed: a SwiftUI scene's window carries it
    /// by default, and a window without it ignores `toggleFullScreen(_:)` silently. The
    /// `styleMask` check keeps the call idempotent, because toggling a window that is already
    /// full screen would put it back on the shared Space — which is the state this exists to
    /// leave.
    @MainActor
    private static func enterFullScreen(_ window: NSWindow) {
        window.collectionBehavior.insert(.fullScreenPrimary)
        guard !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    /// Brings the app in front of every other application again.
    ///
    /// Repeatable, and repeated on purpose. Placing the window once is not enough: a launch, a
    /// connect, and a first page of mail take a few seconds, and whatever else is running takes
    /// the foreground back in the meantime.
    ///
    /// Secondary to the full-screen Space now rather than the mechanism. Kept because it costs
    /// nothing and covers the window between launch and the full-screen transition finishing.
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
    /// is right for an app and wrong for this. `NSRunningApplication.activate(options:)` on the
    /// current process does not ask — though on recent macOS it is refused too when another
    /// application holds the foreground, which is why the full-screen Space is what the suite
    /// actually depends on.
    @MainActor
    private static func forceToForeground() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}
#endif

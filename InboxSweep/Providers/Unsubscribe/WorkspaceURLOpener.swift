import AppKit
import Foundation

/// Opens a URL with whichever app the user has chosen for it.
///
/// The production ``ExternalURLOpening``. It is four lines because there is nothing else it
/// should do: `NSWorkspace.open(_:)` hands the URL to the user's default browser or mail
/// client, which then shows them a window they can see and close. InboxSweep does not learn the
/// page's contents, does not know whether the user completed anything, and does not follow up.
nonisolated struct WorkspaceURLOpener: ExternalURLOpening {

    func open(_ url: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(url) }
    }
}

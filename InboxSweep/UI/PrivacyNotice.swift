import SwiftUI

/// The privacy claims the app makes, in one place.
///
/// Deliberately limited to things this version actually does. There is no claim about
/// encryption, anonymity, or auditing, because none of that is implemented — overstating it
/// here would be the easiest way to mislead someone about their own mail.
nonisolated enum PrivacyNotice {

    struct Point: Identifiable {
        let id = UUID()
        let symbol: String
        let text: String
    }

    static let points: [Point] = [
        Point(
            symbol: "eye",
            text: "Read-only. InboxSweep asks Google for permission to read message details, and nothing else."
        ),
        Point(
            symbol: "hand.raised",
            text: "Nothing is deleted, archived, marked, moved, or sent. This version has no way to change your mailbox."
        ),
        Point(
            symbol: "desktopcomputer",
            text: """
                Message details stay on this Mac. They are kept in memory while the app is open \
                and saved to a file inside InboxSweep's own container so relaunching doesn't \
                re-read your whole inbox. Disconnecting deletes that file.
                """
        ),
        Point(
            symbol: "nosign",
            text: "No message is sent to an AI service, and there is no analytics or telemetry of any kind."
        ),
        Point(
            symbol: "key",
            text: "Your Google password is typed into Google's own sign-in window. InboxSweep never sees it."
        ),
    ]

    static let summary = "InboxSweep reads. It never writes."
}

/// A compact, scannable rendering of ``PrivacyNotice/points``.
struct PrivacyNoticeView: View {
    var points: [PrivacyNotice.Point] = PrivacyNotice.points

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(points) { point in
                Label {
                    Text(point.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: point.symbol)
                        .foregroundStyle(.tint)
                        .frame(width: 18)
                }
            }
        }
        .accessibilityIdentifier("privacy.notice")
    }
}

// Previews are development-only, and some of them run on the debug-only sample
// mailbox, so the whole block stays out of release builds.
#if DEBUG
#Preview {
    PrivacyNoticeView()
        .padding(32)
        .frame(width: 520)
}
#endif

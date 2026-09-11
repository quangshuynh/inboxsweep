import SwiftUI

/// The privacy claims the app makes, in one place.
///
/// Deliberately limited to things this version actually does. There is no claim about
/// encryption, anonymity, or auditing, because none of that is implemented: overstating it
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
            text: """
                InboxSweep reads your message details: who wrote, the subject, the date, the \
                labels. Never the message itself: bodies and attachments are not requested.
                """
        ),
        Point(
            symbol: "hand.raised",
            text: """
                The one change it can make is archiving a single message you pick and confirm, \
                which takes it out of your Inbox without deleting it, and you can undo that. \
                Nothing is deleted, trashed, marked, sent, or unsubscribed from, and nothing is \
                ever changed for a whole sender or on its own.
                """
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
            symbol: "wand.and.sparkles",
            text: """
                Suggestions are worked out on this Mac from the details already fetched, using \
                fixed rules you can read. Nothing is sent anywhere to produce one.
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

    /// The one-line claim shown in the dashboard footer.
    ///
    /// It used to read "InboxSweep reads. It never writes." That sentence stopped being true
    /// the moment a single-message archive existed, and leaving it there would have been the
    /// most quietly misleading string in the app: a promise the code no longer keeps, in the
    /// place a user is most likely to take it at face value.
    static let summary = "InboxSweep reads. It archives one message only when you confirm it."
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

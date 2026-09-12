import SwiftUI

/// Renders a ``SessionNotice`` as a quiet, non-blocking box.
///
/// Deliberately not an alert and not an error screen. Both situations it reports, a sign-in
/// that could not be restored and one that could not be saved, leave the app perfectly
/// usable. What they must not do is happen invisibly.
struct SessionNoticeView: View {

    let notice: SessionNotice

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.symbolName)
                    .foregroundStyle(.orange)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.title)
                        .font(.headline)
                        .accessibilityIdentifier("sessionNotice.title")
                    Text(notice.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sessionNotice.message")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .accessibilityIdentifier("sessionNotice")
    }
}

// Previews are development-only, and some of them run on the debug-only sample
// mailbox, so the whole block stays out of release builds.
#if DEBUG
#Preview {
    VStack(spacing: 16) {
        SessionNoticeView(notice: .authorizationEnded)
        SessionNoticeView(
            notice: .credentialStoreUnreadable(
                reason: "The Keychain declined access to the saved sign-in (errSecInteractionNotAllowed (-25308))."
            )
        )
        SessionNoticeView(
            notice: .notPersisted(
                reason: "InboxSweep couldn't save this sign-in to the Keychain, so you'll need to connect again next launch."
            )
        )
    }
    .padding(24)
    .frame(width: 560)
}
#endif

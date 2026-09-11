import SwiftUI

/// The starting screen: what the app does, what it will ask for, and what it will not do.
///
/// This screen is the app's consent conversation. It says plainly that the app is
/// read-only and names the exact permission before the user is sent to Google, so nothing
/// about the Google consent sheet comes as a surprise.
struct SignedOutView: View {

    let appModel: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let notice = appModel.session.notice {
                    SessionNoticeView(notice: notice)
                }
                header
                Divider()
                permissionSection
                Divider()
                PrivacyNoticeView()
                connectSection
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("signedOut.screen")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "tray.full")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("InboxSweep")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("signedOut.title")

            Text("See who is filling up your inbox, and what to do about it.")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("""
                InboxSweep groups your mail by sender, says which senders look worth cleaning up \
                and why, and can show you what a cleanup would affect before anything happens. \
                It changes nothing: this version can recommend and preview, but it has no way to \
                archive, delete, or alter your mail. Deciding what to do stays with you.
                """)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What Google will ask you to allow")
                .font(.headline)

            Text(GmailScope.userFacingDescription)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("""
                That permission cannot change your mail. InboxSweep does not request access to \
                message bodies or attachments, and it does not request permission to send, delete, \
                label, or modify anything.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var connectSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if appModel.isProviderConfigured {
                Button {
                    appModel.session.connect()
                } label: {
                    Label("Connect Gmail", systemImage: "link")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("signedOut.connectButton")
            } else {
                unconfiguredNotice
            }

            #if DEBUG
            Button("Explore with sample data") {
                appModel.useSampleData()
            }
            .accessibilityIdentifier("signedOut.sampleDataButton")
            .help("Opens the dashboard with synthetic mail. No Google account is involved.")
            #endif
        }
    }

    private var unconfiguredNotice: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Google sign-in isn't set up yet", systemImage: "wrench.and.screwdriver")
                    .font(.headline)
                Text(GmailOAuthConfiguration.missingConfigurationReason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .accessibilityIdentifier("signedOut.notConfigured")
    }
}

// Previews are development-only, and some of them run on the debug-only sample
// mailbox, so the whole block stays out of release builds.
#if DEBUG
#Preview {
    SignedOutView(appModel: AppModel())
        .frame(width: 900, height: 700)
}
#endif

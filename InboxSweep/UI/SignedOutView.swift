import SwiftUI

/// The starting screen: what the app does, what it will ask for, and what it will not do.
///
/// This screen is the app's consent conversation, and since the app gained the ability to
/// archive a message it is carrying more weight than it used to. Google's own consent sheet
/// will say something close to "read, compose, send and permanently delete all your email" for
/// `gmail.modify`, which is both alarming and — for what this app does with it — wrong. The
/// only defence against that is to say first, here, exactly what the permission allows, exactly
/// what InboxSweep does with it, and exactly what it still cannot do, in terms specific enough
/// to be checked.
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
                and why, and shows you what a cleanup would affect before anything happens. \
                The one change it can make is archiving a single message you pick out and \
                confirm — and undoing it. It cannot act on a sender, run a cleanup plan, or \
                delete anything. Deciding what happens stays with you, one message at a time.
                """)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What Google will ask you to allow")
                .font(.headline)

            permission(
                symbol: "eye",
                title: "Reading your message details",
                detail: GmailScope.readingDescription
            )

            permission(
                symbol: "archivebox",
                title: "Changing which labels a message carries",
                detail: GmailScope.archivingDescription
            )

            // The honest caveat, not buried. Google's consent sheet describes this permission
            // in its broadest terms, and a user who reads that after being told "InboxSweep
            // can archive" deserves to have been warned that the two describe the same grant.
            Label {
                Text("""
                    Google grants the second one as a single permission and describes it in its \
                    broadest terms on the consent screen. InboxSweep's use of it is limited to \
                    adding and removing the Inbox label on one message at a time, at your \
                    confirmation — that limit is in the app's code, not in the permission.
                    """)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Text(GmailScope.stillNotGrantedDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("signedOut.permissions")
    }

    private func permission(symbol: String, title: String, detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 18)
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

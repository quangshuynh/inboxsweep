import Foundation
import Observation

/// The composition root: decides which provider the app runs against and owns the session.
///
/// Keeping provider selection here means no view and no domain type has to know whether it is
/// looking at Gmail or at synthetic data.
@MainActor
@Observable
final class AppModel {

    /// The session the window is currently showing.
    private(set) var session: InboxSessionModel

    /// Whether an OAuth client ID was found. When it was not, the signed-out screen explains
    /// what to do instead of offering a connect button that could only fail.
    let isProviderConfigured: Bool

    /// Whether the app is running against synthetic data rather than a real mailbox.
    private(set) var isUsingSampleData = false

    /// The store the real session persists its loaded window to.
    ///
    /// Held here rather than created per session so that signing out and back in reuses the
    /// same file rather than leaving a second one behind.
    private let cache = FileInboxCacheStore()

    /// The store the real session persists preview selections to.
    ///
    /// Held here for the same reason ``cache`` is: signing out and back in reuses one file
    /// rather than leaving a second behind.
    private let planStore = FileCleanupPlanStore()

    /// The local record of what the app has actually changed.
    ///
    /// Held here alongside the other stores for the same reason: one file, reused across a
    /// sign-out and back in, rather than a second one left behind.
    private let mutationRecords = FileMutationTransactionStore()

    init() {
        let configuration = GmailOAuthConfiguration.load()
        isProviderConfigured = configuration != nil
        session = InboxSessionModel(
            provider: GmailProvider(
                configuration: configuration,
                credentialStore: Self.credentialStore()
            ),
            cache: cache,
            planStore: planStore,
            mutationRecords: mutationRecords
        )

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(Self.sampleDataLaunchArgument) {
            useSampleData()
        }
        #endif
    }

    /// The store the real provider persists its refresh token to.
    ///
    /// Always the Keychain, except under ``ignoreStoredCredentialsLaunchArgument``.
    private static func credentialStore() -> GmailCredentialStoring {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(ignoreStoredCredentialsLaunchArgument) {
            return InMemoryCredentialStore()
        }
        #endif
        return KeychainCredentialStore()
    }

    #if DEBUG
    /// Launch argument that starts the app on synthetic data, used by the UI tests.
    static let sampleDataLaunchArgument = "--sample-data"

    /// Launch argument that starts the app with an empty, process-lifetime credential store,
    /// so the signed-out screen appears whether or not this Mac has a saved sign-in.
    ///
    /// The UI test for that screen used to launch the app with no arguments at all, which made
    /// it pass or fail on whether the developer happened to be connected to Gmail — and, when
    /// they were, drove a test run through their real mailbox. Nothing else about the launch
    /// changes: the same provider, the same configuration, the same screen. Only the Keychain
    /// is left out of it, and the real item is neither read nor written.
    static let ignoreStoredCredentialsLaunchArgument = "--ignore-stored-credentials"

    /// Switches to the synthetic mailbox so the dashboard can be exercised without a Google
    /// account. Debug builds only.
    ///
    /// Runs without a cache: invented mail has no business being written to disk, and a
    /// sample run must not disturb the real account's stored window.
    ///
    /// It also runs without any way to archive. ``SampleMailProvider`` vends no mutation
    /// boundary, so the sample session has no archiver at all — the Archive control is absent
    /// rather than disabled, because there is no mailbox behind it to change.
    func useSampleData() {
        isUsingSampleData = true
        session = InboxSessionModel(
            provider: SampleMailProvider(),
            fetchRequest: MailFetchRequest(limit: 60)
        )
        session.connect()
    }

    /// Returns to the real Gmail provider, signed out.
    func useRealProvider() {
        isUsingSampleData = false
        session = InboxSessionModel(
            provider: GmailProvider(
                configuration: GmailOAuthConfiguration.load(),
                credentialStore: Self.credentialStore()
            ),
            cache: cache,
            planStore: planStore,
            mutationRecords: mutationRecords
        )
    }
    #endif
}

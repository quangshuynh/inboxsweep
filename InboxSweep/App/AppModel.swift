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

    init() {
        let configuration = GmailOAuthConfiguration.load()
        isProviderConfigured = configuration != nil
        session = InboxSessionModel(
            provider: GmailProvider(configuration: configuration),
            cache: cache,
            planStore: planStore
        )

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(Self.sampleDataLaunchArgument) {
            useSampleData()
        }
        #endif
    }

    #if DEBUG
    /// Launch argument that starts the app on synthetic data, used by the UI tests.
    static let sampleDataLaunchArgument = "--sample-data"

    /// Switches to the synthetic mailbox so the dashboard can be exercised without a Google
    /// account. Debug builds only.
    ///
    /// Runs without a cache: invented mail has no business being written to disk, and a
    /// sample run must not disturb the real account's stored window.
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
            provider: GmailProvider(configuration: GmailOAuthConfiguration.load()),
            cache: cache,
            planStore: planStore
        )
    }
    #endif
}

import Foundation

/// How much of a scope to read in one go.
///
/// The proposal engine only ever reasons over the loaded window, so how deep that window goes
/// is the single biggest influence on what the app says: a sender who looks like a three-month
/// newsletter over 250 messages may look like a two-year one over 2,500. Making the depth an
/// explicit, named choice puts that where the user can see it, rather than leaving it as a
/// constant they have to discover by clicking **Load more** repeatedly.
///
/// ### Why there is a ceiling
///
/// Gmail's list endpoint returns identifiers only, so every message costs one further metadata
/// request. A thousand messages is a thousand requests; an unbounded "load everything" over a
/// large mailbox would be tens of thousands, which is how an account gets throttled and how a
/// well-meaning button turns into an accidental denial of service against its own user.
///
/// So there is no unbounded option. ``deepest`` stops at ``safetyLimit`` and the UI says so,
/// rather than implying whole-mailbox coverage the app has not achieved.
nonisolated struct MailboxLoadDepth: Hashable, Sendable, Identifiable {

    /// The most messages any single depth will load, however many pages the provider offers.
    ///
    /// 2,500 messages is roughly 2,500 metadata requests: at the fetcher's bounded concurrency
    /// that is a minute or two of steady, well-behaved traffic, and it is enough history for
    /// the proposal rules to say something about a monthly sender. Raising it is a deliberate
    /// edit here, with the request cost in view.
    static let safetyLimit = 2_500

    /// The most messages to load. Always finite.
    let messageLimit: Int

    /// How many messages to ask for per page. Clamped to the provider's own page ceiling.
    let pageSize: Int

    var id: Int { messageLimit }

    init(messageLimit: Int, pageSize: Int = MailFetchRequest.defaultLimit) {
        self.messageLimit = min(max(messageLimit, 1), Self.safetyLimit)
        self.pageSize = min(max(pageSize, 1), 500)
    }

    /// How many pages this depth could need, at most.
    var maximumPageCount: Int {
        Int((Double(messageLimit) / Double(pageSize)).rounded(.up))
    }

    /// Whether this depth reads more than the first page.
    var isMultiPage: Bool { maximumPageCount > 1 }

    var displayName: String {
        isDeepest
            ? "As much as possible (\(messageLimit.formatted()) max)"
            : "\(messageLimit.formatted()) messages"
    }

    /// A short form for a compact control.
    var shortDisplayName: String {
        isDeepest ? "Max \(messageLimit.formatted())" : messageLimit.formatted()
    }

    var isDeepest: Bool { messageLimit == Self.safetyLimit }

    // MARK: - Offered depths

    /// One page, which is what a first load has always done.
    static let firstPage = MailboxLoadDepth(messageLimit: MailFetchRequest.defaultLimit)

    /// Everything the provider will list, up to ``safetyLimit``.
    static let deepest = MailboxLoadDepth(messageLimit: safetyLimit, pageSize: 500)

    /// The depths offered in the UI, shallowest first.
    ///
    /// Shallowest first because the first screen should be quick, and because a user who has
    /// not yet seen the dashboard cannot know whether it is worth waiting for 2,500 messages.
    static let offered: [MailboxLoadDepth] = [
        firstPage,
        MailboxLoadDepth(messageLimit: 500, pageSize: 500),
        MailboxLoadDepth(messageLimit: 1_000, pageSize: 500),
        deepest,
    ]
}

import Foundation

/// Local storage for the choices a user made in the preview.
///
/// Deliberately non-throwing, for the same reason ``InboxCacheStoring`` is: a plan that cannot
/// be read means the user re-picks their senders, and a plan that cannot be written means the
/// same thing next launch. Neither is worth an error dialog, and neither should be able to fail
/// an operation that has otherwise succeeded.
///
/// Implementations keep at most one account's plan, so signing into a second account does not
/// leave the first one's selections on disk.
nonisolated protocol CleanupPlanStoring: Sendable {

    /// Returns the stored plan for `account`, or `nil` when there is none to use.
    ///
    /// Returns `nil` (never throws) for a missing, unreadable, corrupt, out-of-date, or
    /// wrong-account file.
    func load(for account: MailAccount) async -> SavedCleanupPlan?

    /// Replaces the stored plan. Any other account's stored plan is discarded.
    func save(_ plan: SavedCleanupPlan) async

    /// Removes the stored plan for `account`.
    func clear(for account: MailAccount) async
}

/// A store that keeps nothing.
///
/// The default, so persistence is something a caller opts into rather than something that
/// happens by surprise, and so the synthetic mailbox, whose senders do not exist, cannot leave
/// a plan behind that a real account might later be offered.
nonisolated struct EphemeralCleanupPlanStore: CleanupPlanStoring {
    init() {}
    func load(for account: MailAccount) async -> SavedCleanupPlan? { nil }
    func save(_ plan: SavedCleanupPlan) async {}
    func clear(for account: MailAccount) async {}
}

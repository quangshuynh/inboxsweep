#if DEBUG
import Foundation

/// A synthetic Activity history for the sample mailbox.
///
/// ### Why this exists
///
/// The Activity screen has four states that read quite differently — a complete archive with its
/// undo still open, a partial one, one that has since been partly undone, and a restore — and
/// none of them can occur on synthetic data. ``SampleMailProvider`` vends no mutation boundary, so
/// a sample run has nothing that could produce a transaction. That is the right design, and it
/// left the populated screen coverable only by hand and by a `#Preview`.
///
/// So the transactions are made rather than performed. This is the *record* of work, seeded into
/// an in-memory store; it is not a capability. The session it is handed to still has no archiver,
/// still reports `archiveCapability == .unsupported`, and still offers no undo — which is itself
/// worth seeing on screen, and is what a UI test asserts.
///
/// Debug-only, behind a launch argument, and in-memory throughout: nothing here is written to
/// disk, and no real account's history is read or touched.
enum SampleActivity {

    /// Launch argument that seeds the sample session's history. Matches
    /// `UITestLaunchArgument.sampleActivity`.
    ///
    /// Ignored unless the app is also running on synthetic data — there is no meaning to seeding
    /// invented history beside a real mailbox, and no way to do so by accident.
    static let launchArgument = "--sample-activity"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// A store holding the four states, or an empty one when the argument was not given.
    static func recordStore(now: Date = Date()) -> EphemeralMutationRecordStore {
        guard isRequested else { return EphemeralMutationRecordStore() }
        return EphemeralMutationRecordStore(seeded: transactions(now: now))
    }

    /// The four transactions, newest last so the store's own ordering does the work.
    ///
    /// Identifiers are invented and deliberately unlike the sample mailbox's own, so the detail
    /// pane exercises the case that matters most for privacy: a row whose messages the window
    /// cannot describe still reads correctly, and says why.
    private static func transactions(now: Date) -> [MailMutationTransaction] {
        let account = SampleMailbox.account.emailAddress.address

        func transaction(
            _ operation: MailMutationOperation,
            ids: [String],
            selected: Int,
            confirmed: Int,
            minutesAgo: Double,
            undoState: MailMutationTransaction.UndoState
        ) -> MailMutationTransaction {
            MailMutationTransaction(
                id: UUID(),
                operation: operation,
                accountAddress: account,
                succeededMessageIDs: ids.map { MailMessageID($0) },
                selectedMessageCount: selected,
                occurredAt: now.addingTimeInterval(-60 * minutesAgo),
                undoState: undoState,
                confirmedMessageCount: confirmed
            )
        }

        return [
            transaction(.restoreToInbox, ids: ["sample-back-1", "sample-back-2"],
                        selected: 2, confirmed: 2, minutesAgo: 1_480, undoState: .notUndoable),
            transaction(.archive, ids: ["sample-half-1", "sample-half-2"],
                        selected: 5, confirmed: 5, minutesAgo: 1_500, undoState: .superseded),
            transaction(.archive, ids: ["sample-gone-1", "sample-gone-2", "sample-gone-3"],
                        selected: 5, confirmed: 3, minutesAgo: 90, undoState: .superseded),
            transaction(.archive, ids: ["sample-recent-1", "sample-recent-2", "sample-recent-3"],
                        selected: 3, confirmed: 3, minutesAgo: 12, undoState: .undoable),
        ]
    }
}
#endif

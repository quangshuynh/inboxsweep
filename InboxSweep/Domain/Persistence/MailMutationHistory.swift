import Foundation

/// The retention policy for one account's mutation history, and the pruning that enforces it.
///
/// Split out of the store so that the rule is one thing, stated once, and testable without a
/// file system. Both the in-memory store and the on-disk one apply *this* — which is what makes
/// "the sample mailbox and a real account prune identically" true rather than coincidental.
///
/// ### The limit, and why this number
///
/// ``entryLimit`` is **100 transactions per account**. The reasoning, in the order it mattered:
///
/// - InboxSweep writes one entry per deliberate user action. There is no automation, no
///   schedule, and no background work that could write one, so 100 entries is on the order of a
///   year of ordinary use for somebody who archives a set every few days — long enough that the
///   Activity screen answers "what has this app done to my mailbox?" rather than "what did it do
///   this week".
/// - An archive and its undo are two entries, so the *useful* depth is nearer fifty operations.
///   That is the number the limit was actually chosen against.
/// - The whole file is read, validated, and rewritten on every mutation. At 100 entries that is
///   a few kilobytes of identifiers, which costs nothing; at ten thousand it would eventually be
///   a visible pause on somebody's Mac at exactly the wrong moment.
/// - It bounds the worst case. 100 entries × ``FileMutationTransactionStore/maximumMessagesPerTransaction``
///   is the absolute ceiling on how many identifiers this app will ever hold for one account,
///   and a bound that can be multiplied out is worth more than one that cannot.
///
/// It is deliberately *not* time-based. A retention policy that expired entries by age would
/// need something to run, and nothing in InboxSweep runs on its own.
nonisolated enum MailMutationHistory {

    /// How many transactions are kept per account.
    ///
    /// Per account by construction: pruning is applied to one account's entries, and the store
    /// keeps one account's entries at a time, so a busy mailbox cannot shorten a quiet one's
    /// history.
    static let entryLimit = 100

    /// One account's transactions, newest first, bounded by ``entryLimit``.
    ///
    /// Three properties, all of which the Activity screen depends on:
    ///
    /// **Deterministic.** Sorted by timestamp, newest first, and tied by identifier — never by
    /// insertion order. Two entries written in the same second would otherwise prune differently
    /// depending on which the file happened to list first, and the same file would then produce
    /// two different histories.
    ///
    /// **The current undo survives.** An entry the app would still offer an undo for is kept
    /// whatever its age, because pruning it would withdraw a real offer — the messages stay
    /// archived and the app quietly stops being able to put them back. At most one transaction
    /// per account is ever undoable, so this can cost at most one entry over the limit.
    ///
    /// **Idempotent.** Pruning an already-pruned list returns it unchanged, which is what lets
    /// the same function run on the way in *and* on the way out without the two disagreeing.
    static func pruned(_ transactions: [MailMutationTransaction]) -> [MailMutationTransaction] {
        let ordered = sorted(transactions)
        guard ordered.count > entryLimit else { return ordered }

        var kept = Array(ordered.prefix(entryLimit))

        // The undoable entry is almost always the newest archive and already inside the window.
        // "Almost always" is not a guarantee, and the cost of being wrong is an offer the user
        // can see and the app can no longer honour, so it is checked rather than assumed.
        if let undoable = ordered.first(where: \.isUndoable),
           !kept.contains(where: { $0.id == undoable.id }) {
            kept.removeLast()
            kept.append(undoable)
            kept = sorted(kept)
        }

        return kept
    }

    /// Newest first, with a total order rather than a merely-descending one.
    ///
    /// The identifier tiebreak is what makes it total: `sort(by:)` is not stable in Swift, so
    /// entries sharing a timestamp would otherwise come back in an unspecified order and the
    /// prune above would be reading a coin toss.
    static func sorted(_ transactions: [MailMutationTransaction]) -> [MailMutationTransaction] {
        transactions.sorted {
            $0.occurredAt == $1.occurredAt
                ? $0.id.uuidString > $1.id.uuidString
                : $0.occurredAt > $1.occurredAt
        }
    }

    /// The transactions belonging to `account`, pruned and ordered.
    ///
    /// The account filter is applied *before* pruning, so one account's entries can never
    /// displace another's — which matters because the file format names the account once at the
    /// top and a hand-edited file could disagree with itself.
    static func history(
        _ transactions: [MailMutationTransaction],
        for account: MailAccount
    ) -> [MailMutationTransaction] {
        pruned(transactions.filter { $0.accountAddress == account.emailAddress.address })
    }
}

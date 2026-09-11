import Foundation

/// Where a user's rules are kept.
///
/// Modelled on ``MailMutationRecording`` rather than invented afresh, because the requirements
/// are the same ones and they have already been thought about once: account-scoped, local,
/// bounded, versioned, and honest about a write it could not perform.
///
/// **There is no remote implementation of this and there is not going to be.** Rules are not
/// synced, not backed up to a service, not sent anywhere, and not counted. A rule is something
/// the user told this copy of InboxSweep on this Mac.
nonisolated protocol SenderRuleStoring: Sendable {

    /// One account's rules, newest first, bounded and deterministically ordered.
    func rules(for account: MailAccount) async -> [SenderRule]

    /// Writes a rule, replacing any rule with the same identifier.
    ///
    /// Reports whether it reached disk. A rule the user believes they created and that was not
    /// written would silently stop applying at the next launch, which they should be told about
    /// rather than left to discover.
    func save(_ rule: SenderRule) async -> SenderRuleWriteOutcome

    /// Removes one rule from one account.
    ///
    /// Account-scoped rather than by identifier alone, so a rule can never be deleted out of a
    /// mailbox that is not the one on screen.
    func delete(ruleID: SenderRule.ID, for account: MailAccount) async -> SenderRuleWriteOutcome

    /// Forgets every rule for `account`.
    ///
    /// Called on disconnect, alongside the cache, the saved plan, and the mutation history.
    func clear(for account: MailAccount) async
}

/// Whether a rule reached durable storage.
///
/// The same shape as ``MutationRecordOutcome`` and separate from it, because the two describe
/// different files and a caller must not be able to pass one where the other is meant.
nonisolated enum SenderRuleWriteOutcome: Equatable, Sendable {

    case stored

    /// It did not reach disk, with a reason that names no path and no address.
    case notStored(reason: String)

    var warning: String? {
        switch self {
        case .stored: nil
        case .notStored(let reason): reason
        }
    }
}

/// The retention and ordering policy for one account's rules.
///
/// Split out of the store exactly as ``MailMutationHistory`` is, so the in-memory store and the
/// on-disk one behave identically rather than coincidentally, and so the policy can be tested
/// without a file system.
nonisolated enum SenderRuleRetention {

    /// How many rules are kept per account.
    ///
    /// **Twenty-five**, and the reasoning is different from the mutation history's. That file
    /// grows on its own as the user works and needs a limit so it cannot grow without end. This
    /// one only ever grows when somebody deliberately creates a rule, reads a review screen, and
    /// confirms — so the limit is not really about size. It is about comprehension: a rules
    /// screen somebody can read in one sitting is a set of rules they can still be said to have
    /// authorized, and a hundred of them is a configuration nobody remembers agreeing to.
    ///
    /// Reaching it is a refusal rather than a silent eviction. Dropping the oldest rule to make
    /// room for a new one would revoke an authorization the user never withdrew, and the whole
    /// point of this feature is that only they may grant or revoke one. See
    /// ``isAtCapacity(_:)``.
    static let ruleLimit = 25

    /// Whether another rule may be created for this set.
    static func isAtCapacity(_ rules: [SenderRule]) -> Bool { rules.count >= ruleLimit }

    /// Newest first, with a total order rather than a merely-descending one.
    ///
    /// The identifier tiebreak is what makes it total: `sort(by:)` is not stable in Swift, so two
    /// rules created in the same second would otherwise come back in an unspecified order and the
    /// list on screen would reshuffle itself between launches.
    static func sorted(_ rules: [SenderRule]) -> [SenderRule] {
        rules.sorted {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString > $1.id.uuidString
                : $0.createdAt > $1.createdAt
        }
    }

    /// One account's rules, ordered, deduplicated by sender, and bounded.
    ///
    /// Deduplicated because two rules for one sender are not two authorizations, they are one
    /// authorization and a bug: the second would match the same mail, archive nothing extra, and
    /// make the rules screen say something untrue about how many decisions the user has made. The
    /// **newest** survives, because it is the one they most recently agreed to.
    ///
    /// Idempotent, which is what lets the same function run on the way in and on the way out
    /// without the two disagreeing.
    static func retained(_ rules: [SenderRule]) -> [SenderRule] {
        var seenSenders = Set<String>()
        let deduplicated = sorted(rules).filter { seenSenders.insert($0.senderKey).inserted }
        return Array(deduplicated.prefix(ruleLimit))
    }

    /// The rules belonging to `account`, filtered before they are bounded.
    ///
    /// Filtered first for the same reason the mutation history filters first: the file names the
    /// account once at the top, and a hand-edited file that disagreed with itself must not let
    /// one account's rules displace another's.
    static func rules(_ rules: [SenderRule], for account: MailAccount) -> [SenderRule] {
        retained(rules.filter { $0.accountAddress == account.emailAddress.address })
    }
}

/// A store that keeps rules for the life of the process and writes nothing.
///
/// The default for a session that has no reason to persist: previews, the synthetic mailbox, and
/// tests that are not about storage. It is a real store rather than an optional, so there is no
/// `if let store` anywhere in the session and no second code path where rule handling behaves
/// differently.
actor EphemeralSenderRuleStore: SenderRuleStoring {

    private var rules: [SenderRule]

    init(rules: [SenderRule] = []) {
        self.rules = rules
    }

    func rules(for account: MailAccount) async -> [SenderRule] {
        SenderRuleRetention.rules(rules, for: account)
    }

    func save(_ rule: SenderRule) async -> SenderRuleWriteOutcome {
        rules.removeAll { $0.id == rule.id }
        rules.append(rule)
        rules = SenderRuleRetention.retained(rules)
        return .stored
    }

    func delete(ruleID: SenderRule.ID, for account: MailAccount) async -> SenderRuleWriteOutcome {
        rules.removeAll { $0.id == ruleID && $0.accountAddress == account.emailAddress.address }
        return .stored
    }

    func clear(for account: MailAccount) async {
        rules.removeAll { $0.accountAddress == account.emailAddress.address }
    }
}

import Foundation

/// Decides which loaded messages a rule may act on, and says why it refused each of the rest.
///
/// Pure, synchronous, and local. It reads messages already in memory and returns a value: nothing
/// here fetches, archives, records, or contacts anybody. That is what makes it the right place to
/// put the matching policy, because the policy can then be tested exhaustively without a provider
/// and without a mutation boundary anywhere near it.
///
/// ### Exact identity, and nothing that resembles it
///
/// A message matches when ``MailMessage/sender``'s ``EmailAddress/groupingKey`` is **equal** to
/// the rule's ``SenderRule/senderKey``. That is it. There is no domain match, no display-name
/// match, no subject keyword, no Levenshtein distance, no "senders like this one", and no
/// category. `news@example.com` and `news@mail.example.com` are different senders, and so are
/// `news@example.com` and `News@Example.com.evil.example` — the first pair because the addresses
/// differ, the second because equality is not prefix matching.
///
/// The unknown-sender bucket is refused outright. ``EmailAddress/unknownGroupingKey`` is the one
/// key that does not identify a person: every sender whose header could not be parsed shares it,
/// so a rule on it would be a rule on "anything malformed", which is exactly the fuzzy authority
/// this feature exists not to have. ``SenderRuleReviewSnapshot`` refuses to freeze one, and this
/// refuses to match one, so neither half depends on the other remembering.
nonisolated enum SenderRuleMatching {

    /// The largest number of messages one rule may archive in a single pass.
    ///
    /// A bound on the blast radius of one load, not a queue. Every message over the limit is
    /// simply left alone and picked up on a later load, which is the same outcome as mail that
    /// had not arrived yet.
    ///
    /// Fifty is chosen against what a load can contain rather than against a feeling: a first
    /// page is 250 messages and a deep load reaches thousands, so a rule created against a
    /// long-dormant sender could otherwise turn one press of Reload into hundreds of writes on
    /// somebody's Gmail quota, sequentially, with the window apparently frozen. Fifty is more
    /// than a week of any ordinary list and small enough that the pass is over in seconds.
    static let maximumMessagesPerPass = 50

    /// Why a message a rule names was not archived.
    ///
    /// Reported rather than silently dropped, because two of these are things the user needs to
    /// be told: a protected message the rule declined to touch is mail sitting in their Inbox
    /// that they may believe was handled, and a message over the pass limit is work deferred.
    nonisolated enum Refusal: Hashable, Sendable {

        /// The message is not in the Inbox, so there is nothing to archive.
        ///
        /// The ordinary case for most of a loaded window, and not worth telling anybody about.
        case notInInbox

        /// The message arrived before the rule was created.
        ///
        /// **This is what makes "future mail" true rather than promised.** A rule created today
        /// finds this sender's last four months already in the loaded window, and archiving them
        /// would be retroactively cleaning a mailbox on an authorization that said nothing about
        /// it. The review screen tells the user their existing mail stays where it is; this is the
        /// line of code that means it.
        ///
        /// A timestamp comparison rather than a remembered set of identifiers, deliberately. It
        /// needs nothing stored beyond ``SenderRule/createdAt``, it cannot drift, and it gives the
        /// same answer on a window loaded today as on one loaded next year.
        case predatesRule

        /// The message trips a protection signal, so the rule refused it.
        ///
        /// See ``SenderRuleMatching/protectionPolicy``.
        case protected(CleanupExclusionReason)

        /// InboxSweep has already tried this message during this session.
        case alreadyAttempted

        /// The pass was full.
        case overPassLimit

        /// Whether this is something the user should be shown rather than merely recorded.
        var isWorthSurfacing: Bool {
            switch self {
            case .protected, .overPassLimit: true
            case .notInInbox, .alreadyAttempted, .predatesRule: false
            }
        }
    }

    /// What one rule would do to one loaded window.
    nonisolated struct Outcome: Hashable, Sendable {

        /// The messages the rule may archive, oldest first.
        ///
        /// Oldest first deliberately: if the pass limit cuts the list short, the mail left behind
        /// is the newest, which is the mail the user is most likely to want to see anyway.
        let matched: [MailMessageID]

        /// The protected messages the rule declined to touch, with the reason for each.
        ///
        /// Surfaced rather than swallowed. A rule quietly skipping somebody's order confirmation
        /// and saying nothing would leave them believing the sender was handled.
        let protected: [(id: MailMessageID, reason: CleanupExclusionReason)]

        /// How many matching Inbox messages were left for a later pass by the limit.
        let deferredCount: Int

        static let none = Outcome(matched: [], protected: [], deferredCount: 0)

        var isEmpty: Bool { matched.isEmpty }

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.matched == rhs.matched
                && lhs.deferredCount == rhs.deferredCount
                && lhs.protected.map(\.id) == rhs.protected.map(\.id)
                && lhs.protected.map(\.reason) == rhs.protected.map(\.reason)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(matched)
            hasher.combine(deferredCount)
            hasher.combine(protected.map(\.id))
        }
    }

    /// What a rule would do to `messages`, given what has already been tried this session.
    ///
    /// - Parameters:
    ///   - rule: The rule to evaluate. A disabled rule matches nothing; so does one belonging to
    ///     another account, and so does one whose action this build does not recognise.
    ///   - account: The account currently connected.
    ///   - messages: The loaded window, in whatever order it is held.
    ///   - alreadyAttempted: Messages this session has already sent to the boundary for this
    ///     rule, successfully or not. See ``InboxSessionModel`` for why that set exists.
    static func outcome(
        of rule: SenderRule,
        for account: MailAccount,
        in messages: [MailMessage],
        alreadyAttempted: Set<MailMessageID>
    ) -> Outcome {
        guard rule.isEnabled,
              rule.isExecutable,
              rule.accountAddress == account.emailAddress.address,
              rule.senderKey != EmailAddress.unknownGroupingKey,
              !rule.senderKey.isEmpty
        else { return .none }

        // Oldest first, with the identifier tiebreak that makes the order total rather than
        // merely ascending: two messages sharing a timestamp would otherwise be cut differently
        // by the pass limit from one load to the next.
        let candidates = messages
            .filter { $0.sender.groupingKey == rule.senderKey }
            .sorted {
                $0.receivedAt == $1.receivedAt
                    ? $0.id.rawValue < $1.id.rawValue
                    : $0.receivedAt < $1.receivedAt
            }

        var matched: [MailMessageID] = []
        var protected: [(id: MailMessageID, reason: CleanupExclusionReason)] = []
        var deferred = 0

        for message in candidates {
            switch refusal(
                for: message,
                under: rule,
                alreadyAttempted: alreadyAttempted,
                matchedSoFar: matched.count
            ) {
            case .none:
                matched.append(message.id)
            case .protected(let reason):
                protected.append((message.id, reason))
            case .overPassLimit:
                deferred += 1
            case .notInInbox, .alreadyAttempted, .predatesRule:
                continue
            }
        }

        return Outcome(matched: matched, protected: protected, deferredCount: deferred)
    }

    /// Why this one message is not archivable by a rule, or `nil` when it is.
    ///
    /// The order matters and is the order a person would check in: is it even in the Inbox, is it
    /// mail the rule was ever about, have we been here before, is it protected, is the pass full.
    /// Protection is checked before the pass limit so a protected message is always reported as
    /// protected rather than as deferred, which are very different things to tell somebody.
    static func refusal(
        for message: MailMessage,
        under rule: SenderRule,
        alreadyAttempted: Set<MailMessageID>,
        matchedSoFar: Int
    ) -> Refusal? {
        guard message.labels.contains(.inbox) else { return .notInInbox }
        guard message.receivedAt > rule.createdAt else { return .predatesRule }
        guard !alreadyAttempted.contains(message.id) else { return .alreadyAttempted }
        if let reason = protectionReason(for: message) { return .protected(reason) }
        guard matchedSoFar < maximumMessagesPerPass else { return .overPassLimit }
        return nil
    }

    /// The protection policy for automatic execution, which is the conservative one.
    ///
    /// ### Why an old authorization does not outrank a present signal
    ///
    /// The user authorized a rule against a sender, at a moment, on the evidence they had then.
    /// They did not authorize it against *this message*, which they have never seen, and which
    /// may be the one piece of mail from that sender that matters: the receipt, the security
    /// alert, the reply. Protection exists precisely to catch that, and a rule that overrode it
    /// would be trading the app's most valuable safeguard for the convenience of not seeing two
    /// messages in an Inbox.
    ///
    /// So a protected message is **refused and surfaced**, never archived. The user is told which
    /// messages were left behind and why, and they can archive them themselves from the ordinary
    /// review, where the confirmation says out loud that they are archiving protected mail.
    ///
    /// The signals are ``SenderProtection/protectionReason(for:)``: a star the user added, a flag
    /// Gmail applied, a subject that names something worth keeping (security, financial,
    /// healthcare, employment, government, travel, receipts and orders), or a subject that reads
    /// as part of a conversation. Exactly the same rules the manual path uses, asked of the same
    /// function, so the two cannot drift apart.
    static func protectionReason(for message: MailMessage) -> CleanupExclusionReason? {
        guard let reason = SenderProtection.protectionReason(for: message), reason.isProtective else {
            return nil
        }
        return reason
    }
}

import Foundation

/// One thing the user has explicitly authorized InboxSweep to do to future mail from one sender.
///
/// ### What a rule is, and the three words it is not
///
/// It is **not a Gmail filter.** InboxSweep holds no settings scope and can create nothing in
/// somebody's Google account; see ``GmailScope/prohibited``. A rule lives in a file on this Mac
/// and means nothing to Gmail.
///
/// It is **not a schedule.** Nothing in InboxSweep runs on its own. There is no daemon, no login
/// item, no background refresh, and no timer that outlives the app. A rule is an instruction
/// InboxSweep follows *while it is loading mail*, which is only ever when somebody has opened it
/// or asked it to reload.
///
/// It is **not a proposal.** ``SenderCleanupProposal`` is the app's opinion, computed fresh every
/// launch and never stored. A rule is the user's decision, stored because it is theirs. The app
/// can suggest that a rule might be useful; only a person can create one, and the suggestion is
/// inert until they do. See ``SenderRuleReviewSnapshot`` for the boundary that enforces that.
///
/// ### Why the action is one case
///
/// ``Action`` could have been a protocol, a list of label operations, or an enum with a dozen
/// members. It is one case, and that is a product decision rather than a first increment. The
/// app's whole authority over a mailbox is adding or removing `INBOX` on one named message
/// (``MailMessageArchiving``), and a rule must not be the thing that widens it. Automatic
/// deletion, trashing, spam reporting, marking read, forwarding, replying, blocking, arbitrary
/// labelling, and (emphatically) automatic unsubscribing are all absent, and absent in the
/// strong sense: there is no case to construct, so there is no code path to reach.
///
/// ### The privacy cost, stated rather than buried
///
/// A rule is the first thing InboxSweep writes down that **names a sender**. Everything else it
/// persists names messages by provider identifier and describes none of them: the mutation
/// history (``MailMutationTransaction``) holds no addresses, and the unsubscribe history holds a
/// destination host rather than a mailbox. A rule cannot work that way, because the question it
/// answers is "is this new message from that sender?" and there is no way to ask that without
/// holding the sender.
///
/// So the cost is real, and it is bounded to exactly what execution needs: one normalized
/// address per rule, plus the display value already shown on screen. No subjects, no message
/// identifiers, no counts, no history of what the rule has matched. The file is owner-readable
/// only, excluded from backups, and deleted with the account when the user disconnects, exactly
/// like the other two. `docs/rules.md` says all of this in the same words.
nonisolated struct SenderRule: Identifiable, Hashable, Sendable {

    /// Stable identity for this rule, used by the UI and by the Activity entries it produces.
    let id: UUID

    /// The account this rule belongs to.
    ///
    /// Every read, every write, and every execution is filtered on it. A rule created while one
    /// mailbox was connected is invisible and inert while another is, which is the same isolation
    /// the mutation history and the unsubscribe history already have.
    let accountAddress: String

    /// The exact, normalized sender address this rule matches.
    ///
    /// ``EmailAddress/groupingKey``, which for any sender with a parseable address is the
    /// lowercased address itself. **Equality, and nothing else.** There is no prefix match, no
    /// domain match, no display-name match, no subject match, and no similarity score anywhere in
    /// this type or in ``SenderRuleMatching``, because a rule the user cannot predict the effect
    /// of is a rule they cannot meaningfully authorize.
    let senderKey: String

    /// The sender as the screens name it, frozen when the rule was created.
    ///
    /// Display only. It is never matched on, and a sender who changes their display name matches
    /// exactly as before, because the address did not change.
    let senderDisplayValue: String

    /// What InboxSweep does to a matching message.
    let action: Action

    /// Whether the rule runs.
    ///
    /// A disabled rule is kept rather than deleted, because "pause this" and "I was wrong to
    /// create this" are different decisions and a user who wants the first should not have to
    /// re-create the rule to undo it.
    let isEnabled: Bool

    /// When the user authorized it.
    let createdAt: Date

    init(
        id: UUID = UUID(),
        accountAddress: String,
        senderKey: String,
        senderDisplayValue: String,
        action: Action = .archiveNewInboxMail,
        isEnabled: Bool = true,
        createdAt: Date
    ) {
        self.id = id
        self.accountAddress = accountAddress
        self.senderKey = senderKey
        self.senderDisplayValue = senderDisplayValue
        self.action = action
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    /// The only thing a rule can do.
    ///
    /// An enum with one case rather than a bare marker, so that adding a second is a visible,
    /// deliberate edit here and in `RuleSafetyTests`, rather than a parameter somebody passes.
    nonisolated enum Action: String, Hashable, Sendable, CaseIterable {

        /// Archive a newly loaded Inbox message from this sender, through the existing
        /// message-level boundary.
        ///
        /// "Newly loaded" is the honest part, and it is load-bearing. See
        /// ``executionDescription``.
        case archiveNewInboxMail
    }

    // MARK: - Wording
    //
    // Held here rather than in the views so that every screen making this promise makes it in
    // identical words, and so a test can read the promise without a main-actor hop.

    /// What the rule does, in a few words, for a list row.
    var actionSummary: String { action.summary }

    /// When it can run. The sentence this whole feature turns on.
    var executionDescription: String { action.executionDescription }

    /// Whether this is a rule this build can actually execute.
    ///
    /// Always true today, and asked anyway: a rule read back from a file written by a later build
    /// must be *refused* rather than approximated, and the store's decoder returns `nil` for an
    /// action it does not recognise for the same reason.
    var isExecutable: Bool { Action.allCases.contains(action) }

    /// The same rule, enabled or disabled.
    func settingEnabled(_ enabled: Bool) -> SenderRule {
        SenderRule(
            id: id,
            accountAddress: accountAddress,
            senderKey: senderKey,
            senderDisplayValue: senderDisplayValue,
            action: action,
            isEnabled: enabled,
            createdAt: createdAt
        )
    }
}

nonisolated extension SenderRule.Action {

    /// What the rule does, in a few words.
    var summary: String {
        switch self {
        case .archiveNewInboxMail: "Archive new mail"
        }
    }

    /// What the rule does, as a sentence, with no verb it cannot perform.
    var description: String {
        switch self {
        case .archiveNewInboxMail:
            "Archive messages from this sender, which removes them from your Inbox. They are not deleted."
        }
    }

    /// **When** the rule can run, said plainly because the alternative is a lie.
    ///
    /// InboxSweep has no background process. It sees a message only when it fetches one, and it
    /// fetches only when somebody opens the app or presses Reload. So a rule cannot promise that
    /// mail will skip an Inbox it is not there to watch, and this sentence is what every screen
    /// that mentions a rule says instead.
    var executionDescription: String {
        switch self {
        case .archiveNewInboxMail:
            """
            This runs when InboxSweep loads mail, which is when you open it or press Reload. \
            It is not a Gmail filter and nothing runs while InboxSweep is closed, so matching \
            mail arrives in your Inbox as usual and is archived the next time you look.
            """
        }
    }

    /// The thing a rule will not do, however long it has existed.
    ///
    /// Printed on the review and on the rules list. A sender rule authorizes one verb against one
    /// sender's future mail; it is not standing permission for the app to act on that sender in
    /// any other way, and in particular it is not permission to unsubscribe.
    static let boundaryNote = """
        A rule only archives. It never deletes, trashes, marks, labels, forwards, or replies to \
        anything, and it never unsubscribes you from anything: unsubscribing always needs you to \
        review a destination and confirm it, every time.
        """
}

import Foundation

/// Why InboxSweep refused to create, or refused to keep, a rule.
///
/// Its own type rather than a reuse of ``MailMutationError``, because none of these describes
/// something that happened to a mailbox. Every case here means **nothing was written and nothing
/// was changed**, which is the one thing a person reading the message needs to be sure of, and a
/// shared type with "Gmail refused the change" in it would have made that ambiguous.
nonisolated enum SenderRuleFailure: Error, Hashable, Sendable {

    /// The window moved between reading the review and confirming it.
    case reviewIsStale

    /// A different account is connected now.
    case accountChanged

    /// This sender already has a rule.
    case ruleAlreadyExists

    /// The account is at ``SenderRuleRetention/ruleLimit``.
    case tooManyRules

    /// The sender has no address to match on.
    case senderNotIdentifiable

    /// The rule names an action this build cannot perform.
    ///
    /// Reachable only from a rules file written by a later version of InboxSweep. Refused rather
    /// than approximated: running the one action this build has, in place of one it does not
    /// recognise, would be performing a verb the user authorized something else for.
    case actionNotSupported

    /// What to tell the user, in a sentence that says what did not happen.
    ///
    /// Every one of these ends with the state of the world, because "that didn't work" leaves
    /// somebody wondering whether half of it did.
    var message: String {
        switch self {
        case .reviewIsStale:
            "Your mailbox changed while this was open, so InboxSweep didn't create the rule. Reload and try again."
        case .accountChanged:
            "A different account is connected now, so InboxSweep didn't create the rule."
        case .ruleAlreadyExists:
            "You already have a rule for this sender. Open Rules to change or delete it."
        case .tooManyRules:
            """
            You already have \(SenderRuleRetention.ruleLimit) rules, which is as many as InboxSweep \
            keeps. Delete one in Rules to make room. Nothing was changed.
            """
        case .senderNotIdentifiable:
            """
            InboxSweep couldn't read an address for this sender, and a rule has to match an exact \
            address. No rule was created.
            """
        case .actionNotSupported:
            "This rule asks for something this version of InboxSweep can't do, so it was left alone."
        }
    }
}

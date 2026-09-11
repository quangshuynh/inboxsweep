import Foundation

/// Which slice of the mailbox a preview's numbers actually describe.
///
/// Carried on every plan because it is the single most misleading thing a cleanup preview
/// could omit. "43 messages would be archived" is a very different statement depending on
/// whether the app has read the whole mailbox or the most recent 250 messages of one label.
nonisolated struct CleanupPlanWindow: Hashable, Sendable {

    /// How many messages the app has loaded in total.
    let loadedMessageCount: Int

    /// Whether the provider has more messages past the loaded window.
    let hasMoreBeyondWindow: Bool

    /// Which part of the mailbox was read.
    let scope: MailboxScope

    init(loadedMessageCount: Int, hasMoreBeyondWindow: Bool, scope: MailboxScope = .inbox) {
        self.loadedMessageCount = loadedMessageCount
        self.hasMoreBeyondWindow = hasMoreBeyondWindow
        self.scope = scope
    }

    /// Whether these figures describe only part of what they appear to describe.
    var isPartial: Bool { hasMoreBeyondWindow }

    private var scopeName: String {
        switch scope {
        case .inbox: "inbox"
        case .allMail: "mailbox"
        }
    }

    /// One paragraph stating exactly what the numbers cover — and what they do not.
    var explanation: String {
        if hasMoreBeyondWindow {
            return """
                These figures describe only the \(loadedMessageCount) messages InboxSweep has \
                loaded from your \(scopeName). There is more mail beyond that window which the \
                app has never read, so the real totals for these senders are higher. Load more \
                messages for a fuller picture.
                """
        }

        switch scope {
        case .inbox:
            return """
                These figures cover all \(loadedMessageCount) inbox messages InboxSweep has \
                loaded. Mail outside the inbox — already archived, sent, or filed under other \
                labels — was never read and is not counted.
                """
        case .allMail:
            return """
                These figures cover all \(loadedMessageCount) messages InboxSweep has loaded, \
                which is everything the provider listed for this window.
                """
        }
    }

    /// A one-line form for a table footer.
    var shortExplanation: String {
        hasMoreBeyondWindow
            ? "Counts cover the \(loadedMessageCount) loaded messages only — more mail exists beyond the window."
            : "Counts cover all \(loadedMessageCount) loaded \(scopeName) messages."
    }
}

/// What one planned action would reach, for one sender.
nonisolated struct CleanupPlanEntry: Identifiable, Hashable, Sendable {

    let sender: EmailAddress

    /// The action this entry previews.
    let action: PlannedCleanupAction

    /// The proposal that led here, for context in the preview.
    let proposalKind: CleanupProposalKind

    /// The sender's protection assessment, so a preview can warn even when the user overrode
    /// the suggestion and planned something for a protected sender anyway.
    let protection: SenderProtectionAssessment

    /// Loaded messages from this sender.
    let loadedMessageCount: Int

    /// Loaded messages the action would reach.
    let affectedMessageCount: Int

    /// Every retained message, grouped by exactly why it was retained.
    ///
    /// Invariant: these sum to ``retainedMessageCount``, which is
    /// ``loadedMessageCount`` − ``affectedMessageCount``.
    let exclusions: [CleanupExclusion]

    var id: String { "\(sender.groupingKey)|\(action.id)" }

    var retainedMessageCount: Int { loadedMessageCount - affectedMessageCount }

    /// Messages the action's scope reached but that were held back for their own sake.
    var protectedMessageCount: Int {
        exclusions.filter(\.isProtective).reduce(0) { $0 + $1.messageCount }
    }

    /// The reasons messages were held back for their own sake, in fixed order.
    var protectiveExclusions: [CleanupExclusion] { exclusions.filter(\.isProtective) }

    /// The reasons messages were simply out of the action's scope, in fixed order.
    var scopeExclusions: [CleanupExclusion] { exclusions.filter { !$0.isProtective } }

    /// Whether the user planned something for a sender the rules said to protect.
    ///
    /// Not blocked — the preview is read-only and the user is allowed to look — but said out
    /// loud, because a warning is the whole reason the protection rules exist.
    var contradictsProtection: Bool {
        protection.isProtected && action.movesMessages && affectedMessageCount > 0
    }
}

/// A read-only preview of what a set of cleanups would reach.
///
/// **A plan is a description, not a command.** It holds counts and sentences; it has no
/// message identifiers to act on, no reference to a provider, and no method that does
/// anything. Producing one requires nothing but data already in memory — see
/// ``CleanupPlanner`` — and the safety tests assert that building one issues no provider call
/// at all.
nonisolated struct CleanupPlan: Hashable, Sendable {

    /// One entry per selected sender, in the order they were selected.
    let entries: [CleanupPlanEntry]

    /// What the figures cover.
    let window: CleanupPlanWindow

    /// Which ruleset produced the proposals behind these entries.
    let rulesVersion: Int

    /// An empty plan, for an empty selection.
    static func empty(window: CleanupPlanWindow) -> CleanupPlan {
        CleanupPlan(entries: [], window: window, rulesVersion: CleanupProposalRules.version)
    }

    var isEmpty: Bool { entries.isEmpty }
    var senderCount: Int { entries.count }

    var totalAffectedMessageCount: Int { entries.reduce(0) { $0 + $1.affectedMessageCount } }
    var totalRetainedMessageCount: Int { entries.reduce(0) { $0 + $1.retainedMessageCount } }
    var totalProtectedMessageCount: Int { entries.reduce(0) { $0 + $1.protectedMessageCount } }

    /// Entries where the user planned something for a protected sender.
    var entriesContradictingProtection: [CleanupPlanEntry] { entries.filter(\.contradictsProtection) }

    /// The sentence the preview leads with, so the read-only boundary is never inferred.
    static let disclaimer = """
        This is a preview. InboxSweep has no permission to archive, trash, label, or change \
        any message, and nothing here is sent to Gmail.
        """
}

#if DEBUG
import Foundation

/// An archive boundary and a rule store for the synthetic mailbox, neither of which can reach
/// Gmail.
///
/// ### Why the sample mailbox has these at all
///
/// Because a rule's interesting behaviour is what it does when it *runs*, and none of it could be
/// exercised on synthetic mail while ``SampleMailProvider`` vended no mutation boundary. The
/// alternative was covering rule execution only against somebody's real mailbox, which is exactly
/// what the sample provider exists to avoid.
///
/// ### Why this is still safe
///
/// Both are **off by default**, behind their own launch arguments, matching how the sample mailbox
/// already treats unsubscribing. An ordinary sample run has no archiver and no rules, so the
/// Archive control is *absent* rather than disabled and a synthetic session cannot reach a write
/// even by accident. That property is asserted by the UI suite and is not weakened here.
///
/// And when they are on, ``SampleArchiver`` has no transport, no `URLSession`, and no way to
/// acquire one: it edits a label set it holds in memory and answers in-process. A bug that tried
/// to archive real mail from a sample run would have nothing to send it to.
nonisolated enum SampleRules {

    /// Launch argument that gives the sample session an in-process archive boundary.
    ///
    /// Matches `UITestLaunchArgument.sampleArchiving`.
    static let archivingLaunchArgument = "--sample-archiving"

    /// Launch argument that seeds one enabled rule for the sample mailbox's noisiest sender.
    ///
    /// Matches `UITestLaunchArgument.sampleRules`. It seeds an *authorization*, not a capability:
    /// without ``archivingLaunchArgument`` the session has no boundary and the rule is listed,
    /// inspectable, and inert, which is its own thing worth asserting.
    static let rulesLaunchArgument = "--sample-rules"

    /// The sender the seeded rule is about, and the one the sample mailbox sends most.
    static let seededSenderKey = "newsletter@example.com"

    static var isArchivingRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(archivingLaunchArgument)
    }

    static var areRulesRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(rulesLaunchArgument)
    }

    /// The archive boundary a sample session gets, or none.
    static func archiver() -> (any MailMessageArchiving)? {
        isArchivingRequested ? SampleArchiver() : nil
    }

    /// The rule store a sample session gets: in memory, and seeded only when asked.
    ///
    /// The seeded rule is created **in the past**, because a rule only ever acts on mail newer
    /// than itself (``SenderRuleMatching/Refusal/predatesRule``) and a rule created at launch
    /// would match nothing in a fixed synthetic mailbox. Dated a year back, so every sample
    /// message from that sender is mail the rule was authorized before.
    static func store() -> any SenderRuleStoring {
        guard areRulesRequested else { return EphemeralSenderRuleStore() }
        return EphemeralSenderRuleStore(rules: [
            SenderRule(
                accountAddress: SampleMailbox.account.emailAddress.address,
                senderKey: seededSenderKey,
                senderDisplayValue: "The Daily Digest",
                action: .archiveNewInboxMail,
                isEnabled: true,
                createdAt: Date(timeIntervalSinceNow: -365 * 24 * 60 * 60)
            )
        ])
    }
}

/// An archive boundary that changes an in-memory label set and nothing else.
///
/// The sample counterpart of ``SampleUnsubscriber``: it has no transport and cannot acquire one,
/// so a complete rule pass (matching, archiving, reconciling, and its Activity entry) can be
/// driven on any machine with no socket opened and no real mail touched.
///
/// It is an actor because a pass sends it one message at a time and expects each answer to
/// reflect the last, which is exactly what a real provider does.
actor SampleArchiver: MailMessageArchiving {

    /// The labels this boundary believes each message it has been asked about now carries.
    ///
    /// Seeded lazily from the request rather than from the mailbox: the sample provider's messages
    /// are all Inbox mail, and an archive that has not happened yet needs no entry.
    private var labelsByMessage: [MailMessageID: Set<MailLabel>] = [:]

    /// Always granted. There is no consent screen behind synthetic data and nothing to consent to.
    func archiveCapability() async -> MailMutationCapability { .granted }

    func authorizeArchiving() async throws -> MailMutationCapability { .granted }

    func archive(_ request: MailArchiveRequest) async throws -> MailArchiveReceipt {
        var labels = labelsByMessage[request.messageID] ?? [.inbox]
        labels.remove(.inbox)
        labelsByMessage[request.messageID] = labels
        return MailArchiveReceipt(
            messageID: request.messageID,
            operation: .archive,
            labelsAfterMutation: labels
        )
    }

    func restoreToInbox(_ request: MailArchiveRequest) async throws -> MailArchiveReceipt {
        var labels = labelsByMessage[request.messageID] ?? []
        labels.insert(.inbox)
        labelsByMessage[request.messageID] = labels
        return MailArchiveReceipt(
            messageID: request.messageID,
            operation: .restoreToInbox,
            labelsAfterMutation: labels
        )
    }
}
#endif

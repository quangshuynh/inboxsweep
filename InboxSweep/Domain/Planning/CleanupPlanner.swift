import Foundation

/// One sender the user wants a preview for, and what they want previewed.
nonisolated struct CleanupPlanRequest: Hashable, Sendable, Identifiable {

    /// The sender's grouping key, as used everywhere else in the app.
    let senderKey: SenderSummary.ID

    let action: PlannedCleanupAction

    var id: SenderSummary.ID { senderKey }

    init(senderKey: SenderSummary.ID, action: PlannedCleanupAction) {
        self.senderKey = senderKey
        self.action = action
    }
}

/// Works out what a set of planned actions would reach, using nothing but loaded metadata.
///
/// Pure and synchronous. It takes messages the app has already fetched, counts them, and
/// returns sentences. It holds no provider, performs no I/O, and — by construction — cannot
/// change a mailbox: the only thing it returns is a ``CleanupPlan``, which is data.
///
/// The counting rule that matters is the order of the two filters. An action's *scope* is
/// applied first (older than a cutoff, outside the newest N), and only the messages that
/// survive that are tested for protection. Doing it the other way round would report a starred
/// message from yesterday as "protected from a 90-day archive", which sounds like the app
/// saved it when in fact the action was never going to reach it.
nonisolated enum CleanupPlanner {

    /// Builds a preview for `requests`.
    ///
    /// - Parameters:
    ///   - requests: The senders and actions to preview. Duplicate senders are collapsed,
    ///     first request winning, so a double-click or a re-selection cannot make the same
    ///     mail appear to be affected twice.
    ///   - messagesBySender: Loaded messages keyed by sender grouping key.
    ///   - proposals: Proposals keyed the same way, for the context each entry shows.
    ///   - window: What the loaded messages cover.
    ///   - referenceDate: "Now", passed in so the same inputs always produce the same plan.
    static func plan(
        requests: [CleanupPlanRequest],
        messagesBySender: [SenderSummary.ID: [MailMessage]],
        proposals: [SenderSummary.ID: SenderCleanupProposal],
        window: CleanupPlanWindow,
        referenceDate: Date
    ) -> CleanupPlan {
        var seen: Set<SenderSummary.ID> = []
        var entries: [CleanupPlanEntry] = []

        for request in requests {
            guard seen.insert(request.senderKey).inserted else { continue }
            guard let messages = messagesBySender[request.senderKey], !messages.isEmpty else { continue }

            let proposal = proposals[request.senderKey]
            entries.append(
                entry(
                    for: request,
                    sender: proposal?.sender ?? messages[0].sender,
                    messages: messages,
                    proposalKind: proposal?.kind ?? .review,
                    protection: proposal?.protection ?? .unprotected,
                    referenceDate: referenceDate
                )
            )
        }

        return CleanupPlan(entries: entries, window: window, rulesVersion: CleanupProposalRules.version)
    }

    // MARK: - One sender

    private static func entry(
        for request: CleanupPlanRequest,
        sender: EmailAddress,
        messages: [MailMessage],
        proposalKind: CleanupProposalKind,
        protection: SenderProtectionAssessment,
        referenceDate: Date
    ) -> CleanupPlanEntry {
        var affected = 0
        var exclusionCounts: [CleanupExclusionReason: Int] = [:]

        for (index, message) in newestFirst(messages).enumerated() {
            if let outOfScope = scopeExclusion(
                for: request.action,
                message: message,
                positionFromNewest: index,
                referenceDate: referenceDate
            ) {
                exclusionCounts[outOfScope, default: 0] += 1
            } else if let protected = SenderProtection.protectionReason(for: message) {
                exclusionCounts[protected, default: 0] += 1
            } else {
                affected += 1
            }
        }

        let exclusions = exclusionCounts
            .map { CleanupExclusion(reason: $0.key, messageCount: $0.value) }
            .sorted { $0.reason.rank < $1.reason.rank }

        return CleanupPlanEntry(
            sender: sender,
            action: request.action,
            proposalKind: proposalKind,
            protection: protection,
            loadedMessageCount: messages.count,
            affectedMessageCount: affected,
            exclusions: exclusions
        )
    }

    /// Whether the action's own scope leaves this message alone, and why.
    ///
    /// `positionFromNewest` is zero for the sender's newest loaded message.
    private static func scopeExclusion(
        for action: PlannedCleanupAction,
        message: MailMessage,
        positionFromNewest: Int,
        referenceDate: Date
    ) -> CleanupExclusionReason? {
        switch action {
        case .archiveMessagesOlderThan(let days), .trashMessagesOlderThan(let days):
            let cutoff = referenceDate.addingTimeInterval(-Double(days) * 86_400)
            return message.receivedAt > cutoff ? .newerThanCutoff(days: days) : nil

        case .keepNewest(let count):
            return positionFromNewest < count ? .amongNewestKept(count: count) : nil

        case .reviewSubscription:
            return .actionMovesNoMessages
        }
    }

    /// The sender's messages newest first, with ties broken on ID.
    ///
    /// The same ordering the sender detail list uses, so "the newest 5" in a preview are
    /// visibly the top five on screen rather than an arbitrary five.
    private static func newestFirst(_ messages: [MailMessage]) -> [MailMessage] {
        messages.sorted {
            $0.receivedAt == $1.receivedAt ? $0.id.rawValue < $1.id.rawValue : $0.receivedAt > $1.receivedAt
        }
    }
}

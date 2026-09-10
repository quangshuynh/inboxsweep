import Foundation

/// What InboxSweep suggests about one sender, and every fact behind the suggestion.
///
/// Two things are deliberately true of this type:
///
/// - **It carries no score.** ``strength`` is a named band and ``reasons`` are sentences. The
///   engine counts signals internally; nothing on this type invites the user to trust a number
///   whose derivation they cannot see.
/// - **Its facts are the same facts the dashboard already shows.** Every count and date below
///   is copied from the sender's ``SenderSummary`` and is scoped to the *loaded window*, so a
///   proposal can never appear to know more about the mailbox than the app has read.
nonisolated struct SenderCleanupProposal: Identifiable, Hashable, Sendable {

    // MARK: - Identity

    let sender: EmailAddress

    // MARK: - Suggestion

    /// What is being suggested.
    let kind: CleanupProposalKind

    /// How well the loaded window supports it.
    let strength: ProposalStrength

    /// Why, in presentation order. Never empty.
    let reasons: [ProposalReason]

    /// Reasons to be careful with this sender, whether or not they changed the suggestion.
    let protection: SenderProtectionAssessment

    // MARK: - Facts behind it

    let loadedMessageCount: Int
    let unreadCount: Int
    let starredCount: Int
    let importantCount: Int

    /// Newest and oldest loaded message. Not the sender's first and last message ever.
    let newestReceivedAt: Date
    let oldestLoadedReceivedAt: Date

    /// Mean gap between loaded messages, or `nil` when there is no gap to measure.
    let observedIntervalBetweenMessages: TimeInterval?

    /// The provider's own inbox categories seen on this sender's mail.
    let categoryLabels: Set<MailLabel>

    /// How many loaded messages carried a `List-Unsubscribe` header.
    let listUnsubscribeCount: Int

    /// Protective topics the subject lines suggested, in a fixed order.
    let observedTopics: [SubjectTopic]

    /// Which version of the rules produced this.
    ///
    /// Proposals are recomputed from persisted message metadata on every launch rather than
    /// stored, so a stale one cannot outlive a rules change. This is here so the value is
    /// visible in the UI and in tests, not because anything has to migrate it.
    let rulesVersion: Int

    /// Stable across reloads, because it is the sender's grouping key.
    var id: SenderSummary.ID { sender.groupingKey }

    // MARK: - Convenience

    /// Whether there is any reason to be careful with this sender, protected or merely possible.
    var hasProtectionSignals: Bool { protection.hasAnySignal }

    /// Whether protection stopped this from being a cleanup suggestion.
    var isProtected: Bool { protection.isProtected }

    /// Whether the suggestion points towards removing mail.
    var suggestsCleanup: Bool { kind.isCleanupOriented }

    /// The provider's categories in the app's fixed display order.
    var orderedCategoryLabels: [MailLabel] {
        MailLabel.allCategories.filter(categoryLabels.contains)
            + categoryLabels.filter { !MailLabel.allCategories.contains($0) }
                .sorted { $0.displayName < $1.displayName }
    }

    /// The first `limit` reasons, for a row that has no room for all of them.
    func topReasons(_ limit: Int = 3) -> [ProposalReason] {
        Array(reasons.prefix(limit))
    }

    /// How far back the loaded messages from this sender reach.
    var loadedWindowSpan: TimeInterval {
        max(0, newestReceivedAt.timeIntervalSince(oldestLoadedReceivedAt))
    }
}

import Foundation

/// Turns sender evidence into an explainable proposal.
///
/// Pure, synchronous, deterministic, and free of any notion of "now": the same evidence always
/// produces the same proposal, with the same reasons in the same order. Nothing here calls a
/// provider, reads a clock, consults a model, or sends anything anywhere.
///
/// ## How a proposal is reached
///
/// 1. **Protection first.** ``SenderProtection`` assesses the sender. A corroborated signal
///    ends in *Keep*; an uncorroborated one ends in *Review*. Neither can be overridden by any
///    amount of bulk-mail evidence, because bulk-mail evidence is not evidence that the mail
///    is unwanted. The single exception is a protected sender who is also unmistakably bulk
///    mail, which becomes *Review* rather than *Keep* — see
///    ``CleanupProposalRules/signalsForProtectedReview``.
///
/// 2. **Bulk-mail signals are counted.** Eight independent observations, listed in
///    ``bulkSignals(for:rules:)``. Each is a fact the mailbox stated; none is a conclusion.
///
/// 3. **A pattern is matched, or not.** Newsletter, promotional clutter, and recurring
///    notification each require *three* specific signals to agree — never one. A sender that
///    matches no pattern but trips ``CleanupProposalRules/signalsForCleanupCandidate`` signals
///    becomes the deliberately vague *possible cleanup candidate*.
///
/// 4. **Strength is the count of agreeing signals**, translated into a named band. The count
///    itself never leaves this file.
nonisolated enum CleanupProposalEngine {

    /// One observation that points towards bulk mail.
    ///
    /// The order of this enum is the order signals are evaluated and reasons are emitted, so
    /// it is part of the app's observable behaviour rather than an implementation detail.
    nonisolated enum BulkSignal: Int, CaseIterable, Hashable, Sendable {
        /// The sender fills a noticeable part of the loaded window.
        case highVolume
        /// Gmail files this sender under Promotions.
        case promotionsCategory
        /// Most of the sender's loaded mail carries `List-Unsubscribe`.
        case listMetadata
        /// The address looks machine-operated.
        case automatedSender
        /// The mail arrives on something like a schedule.
        case recurringCadence
        /// Most of the loaded mail is still unread.
        case mostlyUnread
        /// Nothing in the window looks like engagement.
        case noEngagementMarkers
        /// The loaded messages cover a long stretch of history.
        case wideWindow
    }

    // MARK: - Entry points

    /// Evaluates one sender.
    static func evaluate(
        _ evidence: SenderEvidence,
        rules: CleanupProposalRules = .default
    ) -> SenderCleanupProposal {
        let protection = SenderProtection.assess(evidence)
        let signals = bulkSignals(for: evidence, rules: rules)
        let kind = kind(for: evidence, protection: protection, signals: signals, rules: rules)

        return SenderCleanupProposal(
            sender: evidence.sender,
            kind: kind,
            strength: strength(for: kind, signalCount: signals.count, protection: protection, rules: rules),
            reasons: reasons(for: evidence, kind: kind, protection: protection, signals: signals, rules: rules),
            protection: protection,
            loadedMessageCount: evidence.summary.messageCount,
            unreadCount: evidence.summary.unreadCount,
            starredCount: evidence.summary.starredCount,
            importantCount: evidence.summary.importantCount,
            newestReceivedAt: evidence.summary.newestReceivedAt,
            oldestLoadedReceivedAt: evidence.summary.oldestLoadedReceivedAt,
            observedIntervalBetweenMessages: evidence.summary.averageIntervalBetweenLoadedMessages,
            categoryLabels: evidence.summary.categoryLabels,
            listUnsubscribeCount: evidence.summary.listUnsubscribeCount,
            observedTopics: evidence.observedTopics,
            rulesVersion: CleanupProposalRules.version
        )
    }

    /// Evaluates a whole loaded window, keyed by sender.
    ///
    /// Takes the summaries the aggregator already produced rather than recomputing them, so a
    /// proposal can never disagree with the counts shown beside it.
    static func evaluate(
        summaries: [SenderSummary],
        messages: [MailMessage],
        rules: CleanupProposalRules = .default
    ) -> [SenderSummary.ID: SenderCleanupProposal] {
        let evidence = SenderEvidenceBuilder.build(summaries: summaries, messages: messages)
        return Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, evaluate($0, rules: rules)) })
    }

    // MARK: - Signals

    /// Which bulk-mail observations hold for this sender, in ``BulkSignal`` order.
    static func bulkSignals(
        for evidence: SenderEvidence,
        rules: CleanupProposalRules = .default
    ) -> Set<BulkSignal> {
        let summary = evidence.summary
        let count = summary.messageCount
        guard count > 0 else { return [] }

        var signals: Set<BulkSignal> = []

        if count >= rules.highVolumeMessageCount {
            signals.insert(.highVolume)
        }

        if summary.categoryLabels.contains(.categoryPromotions) {
            signals.insert(.promotionsCategory)
        }

        if Double(summary.listUnsubscribeCount) / Double(count) >= rules.listMetadataShare {
            signals.insert(.listMetadata)
        }

        if evidence.hasAutomatedSenderLocalPart {
            signals.insert(.automatedSender)
        }

        // A mean interval exists from two messages, but two messages are an accident; a
        // cadence claim needs enough of them for the mean to mean something.
        if count >= rules.minimumMessagesForCadence,
           let interval = summary.averageIntervalBetweenLoadedMessages,
           rules.recurringInterval.contains(interval) {
            signals.insert(.recurringCadence)
        }

        // Both of the following are *absences*, and an absence observed over two or three
        // messages is not an observation — every sender who has written to you once has no
        // starred mail and nothing that looks like a reply. Below the same floor that gates a
        // cleanup proposal, neither counts.
        if count >= rules.minimumMessagesForCleanupProposal {
            if Double(summary.unreadCount) / Double(count) >= rules.unreadShare {
                signals.insert(.mostlyUnread)
            }

            if summary.starredCount == 0, summary.importantCount == 0, evidence.replyLikeSubjectCount == 0 {
                signals.insert(.noEngagementMarkers)
            }
        }

        if evidence.loadedWindowSpan >= rules.wideWindowSpan {
            signals.insert(.wideWindow)
        }

        return signals
    }

    // MARK: - Classification

    private static func kind(
        for evidence: SenderEvidence,
        protection: SenderProtectionAssessment,
        signals: Set<BulkSignal>,
        rules: CleanupProposalRules
    ) -> CleanupProposalKind {
        switch protection.level {
        case .protected:
            // Bulk-mail evidence never unlocks cleanup for a protected sender. It can only
            // move the suggestion from "leave it" to "you should look at this yourself".
            return signals.count >= rules.signalsForProtectedReview ? .review : .keep

        case .possible:
            return .review

        case .none:
            break
        }

        // Gmail's own Personal category is Gmail saying this is correspondence. That is not
        // strong enough to be a protection signal on its own, but it is more than enough to
        // stop the app proposing cleanup.
        guard !evidence.summary.categoryLabels.contains(.categoryPersonal) else {
            return signals.count >= rules.signalsForReview ? .review : .keep
        }

        guard evidence.summary.messageCount >= rules.minimumMessagesForCleanupProposal else {
            return signals.count >= rules.signalsForReview ? .review : .keep
        }

        // Patterns are checked most-specific first, and each needs three signals to agree, so
        // no single observation can produce a cleanup-oriented suggestion by itself.
        if signals.contains(.promotionsCategory),
           signals.contains(.highVolume),
           signals.contains(.mostlyUnread) || signals.contains(.listMetadata) {
            return .likelyPromotionalClutter
        }

        if signals.contains(.listMetadata),
           signals.contains(.recurringCadence),
           signals.contains(.highVolume) || signals.contains(.wideWindow) {
            return .likelyNewsletter
        }

        if signals.contains(.automatedSender),
           signals.contains(.recurringCadence),
           signals.contains(.highVolume) {
            return .likelyRecurringNotification
        }

        if signals.count >= rules.signalsForCleanupCandidate {
            return .possibleCleanupCandidate
        }

        return signals.count >= rules.signalsForReview ? .review : .keep
    }

    private static func strength(
        for kind: CleanupProposalKind,
        signalCount: Int,
        protection: SenderProtectionAssessment,
        rules: CleanupProposalRules
    ) -> ProposalStrength {
        // "Keep" backed by a corroborated protection signal is a confident answer, even when
        // there is no bulk-mail evidence at all — arguably the most confident one the app has.
        if kind == .keep, protection.isProtected { return .strong }

        if signalCount >= rules.strongStrengthSignalCount { return .strong }
        if signalCount >= rules.moderateStrengthSignalCount { return .moderate }
        return .limited
    }

    // MARK: - Explanation

    private static func reasons(
        for evidence: SenderEvidence,
        kind: CleanupProposalKind,
        protection: SenderProtectionAssessment,
        signals: Set<BulkSignal>,
        rules: CleanupProposalRules
    ) -> [ProposalReason] {
        var reasons: [ProposalReason] = []
        let summary = evidence.summary

        for signal in protection.signals {
            reasons.append(ProposalReason(.protection, signal.explanation))
        }

        switch protection.level {
        case .protected:
            reasons.append(
                ProposalReason(
                    .protection,
                    kind == .review
                        ? "InboxSweep won't propose cleanup here, but there's enough bulk mail from this sender to be worth your own look."
                        : "InboxSweep doesn't propose cleanup for senders with signals like these."
                )
            )
        case .possible:
            reasons.append(
                ProposalReason(
                    .protection,
                    "That's a single, uncorroborated signal, so this is flagged for review rather than cleanup."
                )
            )
        case .none:
            break
        }

        // Emitted in `BulkSignal` order so a sender's explanation reads the same way every
        // time, regardless of how the set iterates.
        for signal in BulkSignal.allCases where signals.contains(signal) {
            if let reason = reason(for: signal, evidence: evidence, rules: rules) {
                reasons.append(reason)
            }
        }

        if summary.messageCount < rules.minimumMessagesForCleanupProposal, !protection.hasAnySignal {
            reasons.append(
                ProposalReason(
                    .insufficientEvidence,
                    "Only \(ProposalPhrasing.loadedMessages(summary.messageCount)) from this sender — too few to suggest anything about the rest."
                )
            )
        }

        if reasons.isEmpty {
            reasons.append(
                ProposalReason(
                    .insufficientEvidence,
                    "Nothing in the loaded window points towards this sender being worth cleaning up."
                )
            )
        }

        return reasons.inPresentationOrder
    }

    private static func reason(
        for signal: BulkSignal,
        evidence: SenderEvidence,
        rules: CleanupProposalRules
    ) -> ProposalReason? {
        let summary = evidence.summary

        switch signal {
        case .highVolume:
            // Named as promotional only when Gmail already said so — the app is reporting
            // Gmail's classification, not adding one.
            let noun = summary.categoryLabels.contains(.categoryPromotions) ? "promotional messages" : "messages"
            return ProposalReason(
                .volume,
                "\(summary.messageCount) \(noun) from this sender in the loaded window"
            )

        case .promotionsCategory:
            return ProposalReason(.providerCategory, "Gmail files this sender's mail under Promotions")

        case .listMetadata:
            return ProposalReason(
                .listMetadata,
                summary.listUnsubscribeCount == summary.messageCount
                    ? "Mailing-list unsubscribe metadata on every loaded message"
                    : "Mailing-list unsubscribe metadata on \(summary.listUnsubscribeCount) of \(summary.messageCount) loaded messages"
            )

        case .automatedSender:
            return ProposalReason(.automatedSender, "Arrives from an automated-looking address")

        case .recurringCadence:
            return ProposalPhrasing.cadence(everySeconds: summary.averageIntervalBetweenLoadedMessages)
                .map { ProposalReason(.cadence, $0) }

        case .mostlyUnread:
            return ProposalReason(
                .engagement,
                "\(summary.unreadCount) of \(ProposalPhrasing.loadedMessages(summary.messageCount)) still unread"
            )

        case .noEngagementMarkers:
            return ProposalReason(.engagement, "No starred, important, or reply-like messages detected")

        case .wideWindow:
            return ProposalPhrasing.windowSpan(evidence.loadedWindowSpan)
                .map { ProposalReason(.window, "Loaded messages span \($0)") }
        }
    }
}

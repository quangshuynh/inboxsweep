import Foundation

/// Reads one sender's loaded messages and reports what unsubscribing from them would involve.
///
/// ### What it is allowed to look at
///
/// Parsed `List-Unsubscribe` metadata, Gmail's own bulk categories, how many messages there
/// are, and how far apart they arrived. That is the whole list, and it is the list requirement
/// 2 of this interval draws: metadata already fetched, nothing that needs a body, and **never**
/// a subject line. A subject that says "Newsletter" is not evidence of an unsubscribe
/// mechanism; the header is the only thing that is.
///
/// ### Which message the mechanism comes from
///
/// The **newest loaded message that carries something actionable**. Senders rotate endpoints,
/// and an unsubscribe link from four months ago is the one most likely to have expired. When
/// the sender's messages disagree, that is recorded as evidence and shown, rather than being
/// resolved by picking an arbitrary one and saying nothing.
///
/// ### It never manufactures confidence
///
/// Recurrence and bulk categories can corroborate; neither can raise the confidence band on
/// its own. A sender that arrives every day with no `List-Unsubscribe` header is
/// ``UnsubscribeOpportunity/Availability/noEvidence``, not a guess — which is the rule that
/// keeps a daily transactional notice from being read as a mailing list.
nonisolated enum UnsubscribeOpportunityBuilder {

    /// Builds the reading for one sender.
    ///
    /// - Parameters:
    ///   - sender: The sender, as the summary names it.
    ///   - messages: That sender's loaded messages, in any order.
    ///   - summary: The aggregate facts, for the corroborating evidence.
    ///   - protection: The archive-protection assessment, carried through untouched.
    static func build(
        sender: EmailAddress,
        messages: [MailMessage],
        summary: SenderSummary?,
        protection: SenderProtectionAssessment = .unprotected
    ) -> UnsubscribeOpportunity {
        let loadedCount = messages.count
        let withHeader = messages.filter(\.unsubscribe.headerWasPresent)

        // Corroboration, which is added to every reading that has any metadata at all and to
        // none that has not. It never decides anything by itself — see the type's own note.
        let corroboration = corroboratingEvidence(summary: summary)

        guard !withHeader.isEmpty else {
            return .none(
                sender: sender,
                loadedMessageCount: loadedCount,
                protection: protection,
                evidence: []
            )
        }

        let newestFirst = withHeader.sorted { $0.receivedAt > $1.receivedAt }
        let distinctMetadata = Set(newestFirst.map(\.unsubscribe)).count

        var evidence: [UnsubscribeEvidence] = [
            .listUnsubscribeHeader(messageCount: withHeader.count, ofLoaded: loadedCount)
        ]

        // The newest message whose header yields something usable. A sender whose latest mail
        // carries a malformed header but whose message from last week carries a good one still
        // gets an offer — from the good one, named as such.
        let source = newestFirst.first { $0.unsubscribe.hasActionableTarget }
        let metadata = source?.unsubscribe ?? newestFirst[0].unsubscribe

        if metadata.declaresOneClickPost, metadata.oneClickURL != nil {
            evidence.append(.oneClickDeclared)
        }
        if metadata.declaresOneClickWithoutHTTPSURL {
            evidence.append(.oneClickDeclaredWithoutURL)
        }
        if distinctMetadata > 1 {
            evidence.append(.metadataVariesAcrossMessages(distinctValues: distinctMetadata))
        }
        // Refused values from *every* loaded message, deduplicated by reason: a sender that
        // sends a javascript: URL once has sent one, whichever message it landed in.
        var seenReasons = Set<UnsupportedUnsubscribeValue.Reason>()
        for reason in newestFirst.flatMap({ $0.unsubscribe.unsupportedValues }).map(\.reason)
        where seenReasons.insert(reason).inserted {
            evidence.append(.unusableValue(reason))
        }

        guard let selection = UnsubscribeMechanismSelection.select(from: metadata) else {
            return UnsubscribeOpportunity(
                sender: sender,
                availability: .ambiguousMetadata,
                confidence: .low,
                evidence: ordered(evidence + corroboration),
                selection: nil,
                sourceMessageID: newestFirst[0].id,
                messagesWithHeader: withHeader.count,
                loadedMessageCount: loadedCount,
                protection: protection
            )
        }

        if selection.hasAlternatives {
            evidence.append(.multipleMechanisms(count: selection.allMechanisms.count))
        }

        return UnsubscribeOpportunity(
            sender: sender,
            availability: availability(for: selection.chosen),
            confidence: confidence(for: selection.chosen, metadata: metadata, variesAcrossMessages: distinctMetadata > 1),
            evidence: ordered(evidence + corroboration),
            selection: selection,
            sourceMessageID: source?.id ?? newestFirst[0].id,
            messagesWithHeader: withHeader.count,
            loadedMessageCount: loadedCount,
            protection: protection
        )
    }

    // MARK: - Rules

    private static func availability(for mechanism: UnsubscribeMechanism) -> UnsubscribeOpportunity.Availability {
        switch mechanism {
        case .oneClick(let url): .oneClickAvailable(url)
        case .webPage(let url): .webPageAvailable(url)
        case .mail(let address): .mailHandoffAvailable(address)
        }
    }

    /// The confidence band.
    ///
    /// One-click is ``UnsubscribeOpportunity/Confidence/standardsDefined`` because RFC 8058
    /// specifies the request exactly; everything else usable is `moderate`, because a URL in a
    /// header is a destination the sender named and not a protocol. Disagreement between a
    /// sender's own messages takes a band off whatever it would otherwise have been — the value
    /// on offer is one of several the sender has used, and that is less certain than one.
    private static func confidence(
        for mechanism: UnsubscribeMechanism,
        metadata: MessageUnsubscribeMetadata,
        variesAcrossMessages: Bool
    ) -> UnsubscribeOpportunity.Confidence {
        let base: UnsubscribeOpportunity.Confidence = mechanism.kind == .oneClick ? .standardsDefined : .moderate
        guard variesAcrossMessages else { return base }
        return UnsubscribeOpportunity.Confidence(rawValue: base.rawValue - 1) ?? .low
    }

    /// Facts about the sender's mail that support — but never establish — a reading.
    private static func corroboratingEvidence(summary: SenderSummary?) -> [UnsubscribeEvidence] {
        guard let summary else { return [] }
        var evidence: [UnsubscribeEvidence] = []

        for label in summary.orderedCategoryLabels where Self.bulkCategories.contains(label) {
            evidence.append(.bulkCategory(label))
        }

        if summary.messageCount >= recurrenceMessageCount {
            evidence.append(
                .recurringSender(
                    messageCount: summary.messageCount,
                    averageInterval: summary.averageIntervalBetweenLoadedMessages
                )
            )
        }

        return evidence
    }

    /// Gmail's own bulk categories. Gmail's judgement, reported as Gmail's.
    ///
    /// Personal is deliberately not here, and neither is Updates: Updates is where a bank puts
    /// a statement as readily as where a shop puts a shipping notice, and treating it as a
    /// bulk-mail signal would be exactly the misreading requirement 2 warns about.
    static let bulkCategories: Set<MailLabel> = [.categoryPromotions, .categoryForums, .categorySocial]

    /// How many loaded messages make a sender "recurring" for the purposes of corroboration.
    static let recurrenceMessageCount = 3

    private static func ordered(_ evidence: [UnsubscribeEvidence]) -> [UnsubscribeEvidence] {
        var seen = Set<UnsubscribeEvidence>()
        return evidence
            .filter { seen.insert($0).inserted }
            .sorted { $0.rank < $1.rank }
    }
}

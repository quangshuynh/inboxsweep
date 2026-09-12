import Foundation

/// What InboxSweep can say about unsubscribing from one sender, and how sure it is.
///
/// ### Why this is not a Boolean
///
/// `isSubscription` would answer a question nobody is actually asking. The questions that
/// matter are *what mechanism is there*, *how do we know*, and *how sure can anyone be*, and
/// a Boolean collapses all three into a claim the app cannot support. A sender with a
/// malformed header is not "not a subscription"; a sender with a perfectly good one-click
/// endpoint may still be the bank.
///
/// So this type keeps the uncertainty: a state that distinguishes "nothing here" from
/// "something here we cannot use", a mechanism that says who would do what, a confidence band
/// that is never a number, and the evidence in full so the user can disagree with it.
///
/// ### It authorizes nothing
///
/// An opportunity is a *reading*. It has no method that acts, it carries no request, and the
/// only way anything reaches a sender's server is a user opening the review, seeing the exact
/// destination, and confirming. `SafetyBoundaryTests` asserts that building one of these sends
/// nothing anywhere.
nonisolated struct UnsubscribeOpportunity: Hashable, Sendable, Identifiable {

    /// The sender this is about.
    let sender: EmailAddress

    /// What is available, if anything.
    let availability: Availability

    /// How much the evidence supports it.
    let confidence: Confidence

    /// Every fact behind it, in a fixed order.
    let evidence: [UnsubscribeEvidence]

    /// The mechanism the review would act on, with the ones it would list beside it.
    ///
    /// `nil` in exactly the states where there is nothing to act on.
    let selection: UnsubscribeSelection?

    /// The message whose headers the mechanism came from.
    ///
    /// Carried because a sender's messages can disagree, and because the stale-review check
    /// re-reads *this* message's metadata before anything is sent. Without it, "the mechanism
    /// has not changed" would be a claim about a sender rather than about a value.
    let sourceMessageID: MailMessageID?

    /// How many of the sender's loaded messages carried the header.
    let messagesWithHeader: Int

    /// How many of the sender's messages are loaded at all.
    let loadedMessageCount: Int

    /// Why this sender may be worth being careful with, carried through unchanged.
    ///
    /// Protection never *hides* an unsubscribe mechanism: a bank's mail can carry a perfectly
    /// real one, and concealing it would be the app deciding what somebody may know about their
    /// own mailbox. What it does is change the tone: see ``cautionNote``.
    let protection: SenderProtectionAssessment

    var id: SenderSummary.ID { sender.groupingKey }

    // MARK: - States

    /// The states an unsubscribe reading can be in.
    ///
    /// Five, because five genuinely different things can be true, and the UI has a distinct
    /// thing to say about each.
    nonisolated enum Availability: Hashable, Sendable {

        /// No loaded message from this sender carried a `List-Unsubscribe` header.
        case noEvidence

        /// A header was there, and nothing usable came out of it, every value refused, or
        /// values that contradict each other. Nothing can be acted on, and saying "no
        /// unsubscribe option" would be a different and untrue statement.
        case ambiguousMetadata

        /// An RFC 8058 one-click endpoint. The only mechanism InboxSweep can perform itself.
        case oneClickAvailable(HTTPSUnsubscribeURL)

        /// An ordinary HTTPS unsubscribe page, for the browser.
        case webPageAvailable(HTTPSUnsubscribeURL)

        /// A `mailto` unsubscribe, for the mail client.
        case mailHandoffAvailable(MailtoUnsubscribeAddress)

        /// Whether anything at all can be acted on.
        var isActionable: Bool {
            switch self {
            case .oneClickAvailable, .webPageAvailable, .mailHandoffAvailable: true
            case .noEvidence, .ambiguousMetadata: false
            }
        }

        /// Whether this state came from a `List-Unsubscribe` header at all.
        ///
        /// True for the three actionable states and for ``ambiguousMetadata``: the family the
        /// interval's brief calls "list-header unsubscribe available", of which one-click, web,
        /// and mail are the specific members.
        var camesFromListHeader: Bool { self != .noEvidence }

        /// A short label for a row or a badge.
        var displayName: String {
            switch self {
            case .noEvidence: "No unsubscribe option"
            case .ambiguousMetadata: "Unsubscribe details unclear"
            case .oneClickAvailable: "One-click unsubscribe"
            case .webPageAvailable: "Unsubscribe page"
            case .mailHandoffAvailable: "Email unsubscribe"
            }
        }
    }

    /// How far the evidence goes.
    ///
    /// A band rather than a number, for the same reason ``ProposalStrength`` is: a percentage
    /// would invite trust in a derivation the user cannot see.
    nonisolated enum Confidence: Int, Hashable, Sendable, Comparable, CaseIterable {

        /// Nothing found.
        case none

        /// Something was declared and cannot be used, or the sender's own messages disagree.
        case low

        /// A well-formed destination from the sender's own header.
        case moderate

        /// A standards-defined one-click endpoint: both headers present, agreeing, and
        /// well-formed. The one case where the mechanics are specified rather than inferred.
        case standardsDefined

        static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }

        var displayName: String {
            switch self {
            case .none: "No evidence"
            case .low: "Unclear"
            case .moderate: "From this sender's own header"
            case .standardsDefined: "Standards-based"
            }
        }

        /// What the band means, said in terms of what was observed.
        var explanation: String {
            switch self {
            case .none:
                "None of this sender's loaded messages carries unsubscribe metadata."
            case .low:
                """
                This sender sent unsubscribe metadata InboxSweep can't act on, or its messages \
                disagree about what it is. Nothing here is reliable enough to act on automatically, \
                and InboxSweep won't guess at what was meant.
                """
            case .moderate:
                """
                The destination below came from this sender's own List-Unsubscribe header. That the \
                header exists does not mean the sender will honour it: only that this is where \
                they said to go.
                """
            case .standardsDefined:
                """
                This sender declares the RFC 8058 one-click standard, which defines exactly what \
                request to send. That makes the mechanics unambiguous. It does not promise the \
                sender will act on it.
                """
            }
        }
    }

    // MARK: - Derived

    var isActionable: Bool { availability.isActionable }

    /// The mechanism a confirmation would act on.
    var mechanism: UnsubscribeMechanism? { selection?.chosen }

    /// Every mechanism, chosen first.
    var mechanisms: [UnsubscribeMechanism] { selection?.allMechanisms ?? [] }

    var hasMultipleMechanisms: Bool { mechanisms.count > 1 }

    /// The evidence that argues against certainty, on its own.
    var cautionaryEvidence: [UnsubscribeEvidence] { evidence.filter(\.isCautionary) }

    /// The sentence shown when a sender looks like mail somebody may need.
    ///
    /// ### Why a protected sender still sees its mechanism
    ///
    /// Archive protection exists because archiving mail somebody wanted is a loss. Unsubscribing
    /// is a different risk in the other direction (it affects mail that has not arrived) and
    /// the sender most likely to be carrying a real, honoured unsubscribe header *and* to be
    /// worth thinking twice about is exactly the bank, the airline, and the pharmacy. Hiding the
    /// mechanism from those would leave a user unable to turn off marketing mail from their own
    /// bank through the app that found it.
    ///
    /// So the mechanism is shown and the tone changes. Nothing here is a rule, nothing here
    /// blocks the action, and the archive protection is not reused as an unsubscribe policy.
    var cautionNote: String? {
        guard protection.hasAnySignal else { return nil }
        let signals = protection.signals.prefix(2).map(\.displayName).joined(separator: ", ")
        return """
            Mail from this sender looks like something you may need: \(signals.lowercased()). \
            Unsubscribing affects what this sender sends you in future, which can include messages \
            like receipts, statements, or security notices if they come through the same list. \
            InboxSweep is showing you the mechanism, not recommending you use it.
            """
    }

    /// Whether the sender's mail carries protective signals at all.
    var needsCaution: Bool { protection.hasAnySignal }

    /// The headline sentence for a sender with nothing to act on.
    var unavailableExplanation: String? {
        switch availability {
        case .noEvidence:
            return """
                None of the \(loadedMessageCount) loaded messages from this sender carries a \
                List-Unsubscribe header, so InboxSweep has no unsubscribe mechanism to offer. \
                That does not mean there isn't one: many senders put an unsubscribe link in the \
                message body, which InboxSweep never reads.
                """
        case .ambiguousMetadata:
            let reasons = evidence.filter(\.isCautionary).map(\.explanation)
            let detail = reasons.isEmpty ? "" : " " + reasons.joined(separator: ". ") + "."
            return """
                This sender sent unsubscribe metadata, and InboxSweep can't act on it.\(detail) \
                Rather than guess at what was meant, InboxSweep offers nothing here.
                """
        case .oneClickAvailable, .webPageAvailable, .mailHandoffAvailable:
            return nil
        }
    }

    /// The sentence that separates this from archiving, wherever an unsubscribe is discussed.
    ///
    /// A constant rather than a string in a view, so the promise can be read by a test and is
    /// worded identically on every screen that makes it.
    static let futureMailNote = """
        Archiving changes messages you already have. Unsubscribing is about messages you haven't \
        received yet: it asks the sender to stop sending. It doesn't remove, move, or change a \
        single message already in your mailbox, and InboxSweep can't undo it.
        """

    /// Nothing found, for a sender with no metadata at all.
    static func none(
        sender: EmailAddress,
        loadedMessageCount: Int,
        protection: SenderProtectionAssessment = .unprotected,
        evidence: [UnsubscribeEvidence] = []
    ) -> UnsubscribeOpportunity {
        UnsubscribeOpportunity(
            sender: sender,
            availability: .noEvidence,
            confidence: .none,
            evidence: evidence,
            selection: nil,
            sourceMessageID: nil,
            messagesWithHeader: 0,
            loadedMessageCount: loadedMessageCount,
            protection: protection
        )
    }
}

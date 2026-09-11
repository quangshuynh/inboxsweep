import Foundation

/// One human-readable statement behind a proposal.
///
/// Reasons are produced by the rules, not by the views, for two reasons: a view that composed
/// its own explanation would be a rule the tests cannot reach, and an explanation assembled
/// separately from the decision can drift away from it. What the user reads is what the engine
/// decided on.
nonisolated struct ProposalReason: Identifiable, Hashable, Sendable {

    /// The kind of statement, which also fixes where it appears in a list.
    nonisolated enum Kind: Int, Comparable, Hashable, Sendable {

        /// A protection signal. Always first: if there is a reason to be careful, it leads.
        case protection

        /// How much mail arrived in the loaded window.
        case volume

        /// A category the provider itself applied.
        case providerCategory

        /// `List-Unsubscribe` metadata.
        case listMetadata

        /// How often the sender appears in the loaded window.
        case cadence

        /// The address looks machine-operated.
        case automatedSender

        /// Signs of engagement, or the absence of them.
        case engagement

        /// How much history the loaded window covers.
        case window

        /// There is not enough loaded mail to say anything.
        case insufficientEvidence

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let kind: Kind

    /// The sentence shown to the user. Complete, specific, and free of internal scoring.
    let text: String

    /// Unique within a proposal: no kind is ever emitted twice for the same sender.
    var id: String { "\(kind.rawValue)-\(text)" }

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

nonisolated extension Array where Element == ProposalReason {

    /// Reasons in their fixed presentation order.
    ///
    /// Sorted by kind, with the original order preserved inside a kind, so a sender's
    /// explanation reads identically on every launch — the same stability the sender list
    /// itself is held to.
    var inPresentationOrder: [ProposalReason] {
        enumerated()
            .sorted { lhs, rhs in
                lhs.element.kind == rhs.element.kind
                    ? lhs.offset < rhs.offset
                    : lhs.element.kind < rhs.element.kind
            }
            .map(\.element)
    }
}

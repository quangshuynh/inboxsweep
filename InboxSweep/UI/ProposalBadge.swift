import SwiftUI

/// The compact rendering of a proposal: what it is, and whether to be careful with it.
///
/// The tint is the only place the app uses colour to mean something, so the meanings are kept
/// deliberately dull. Nothing is red: red would read as "this is bad" or "this will delete",
/// and the app is neither judging the sender nor able to remove anything.
struct ProposalBadge: View {

    let proposal: SenderCleanupProposal

    /// Whether to show the protection warning beside the badge.
    var showsProtectionWarning = true

    var body: some View {
        HStack(spacing: 6) {
            Label(proposal.kind.displayName, systemImage: proposal.kind.symbolName)
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .foregroundStyle(tint)
                .lineLimit(1)

            if showsProtectionWarning, proposal.hasProtectionSignals {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.secondary)
                    .help(protectionHelp)
                    .accessibilityLabel(protectionHelp)
            }
        }
        .accessibilityIdentifier("proposal.badge.\(proposal.kind.rawValue)")
    }

    private var protectionHelp: String {
        proposal.isProtected
            ? "InboxSweep found reasons to leave this sender alone."
            : "InboxSweep found a weak signal worth checking before doing anything here."
    }

    /// Muted throughout. A proposal is a suggestion, and a saturated palette would give the
    /// app's guesses more visual authority than the evidence behind them supports.
    private var tint: Color {
        switch proposal.kind {
        case .keep: .secondary
        case .review: .orange
        case .likelyNewsletter, .likelyPromotionalClutter, .likelyRecurringNotification: .accentColor
        case .possibleCleanupCandidate: .accentColor
        }
    }
}

/// The evidence band, as a short piece of secondary text.
struct ProposalStrengthLabel: View {

    let strength: ProposalStrength
    var isCompact = false

    var body: some View {
        Text(isCompact ? strength.shortDisplayName : strength.displayName)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

// Previews are development-only, and some of them run on the debug-only sample
// mailbox, so the whole block stays out of release builds.
#if DEBUG
#Preview {
    let messages = SampleMailbox.messages()
    let summaries = SenderAggregator.aggregate(messages)
    let proposals = CleanupProposalEngine.evaluate(summaries: summaries, messages: messages)

    return VStack(alignment: .leading, spacing: 10) {
        ForEach(summaries) { summary in
            if let proposal = proposals[summary.id] {
                HStack {
                    Text(summary.sender.displayValue).frame(width: 180, alignment: .leading)
                    ProposalBadge(proposal: proposal)
                    Spacer()
                    ProposalStrengthLabel(strength: proposal.strength)
                }
            }
        }
    }
    .padding(24)
    .frame(width: 560)
}
#endif

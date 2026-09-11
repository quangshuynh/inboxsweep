import SwiftUI

/// The full reasoning behind one proposal.
///
/// Every line here comes from the engine. The view chooses layout and nothing else: there is
/// no sentence assembled at this level, because an explanation written next to the pixels
/// could say something the rules did not decide.
struct ProposalReasoningView: View {

    let proposal: SenderCleanupProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(alignment: .leading, spacing: 7) {
                ForEach(proposal.reasons) { reason in
                    ReasonRow(reason: reason)
                }
            }

            if proposal.hasProtectionSignals {
                protectionNotice
            }

            Text("""
                These are observations about the \(ProposalPhrasing.loadedMessages(proposal.loadedMessageCount)) \
                InboxSweep has read from this sender, not a judgement about the sender, and not a \
                claim about mail outside the loaded window.
                """)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("senderDetail.proposal")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProposalBadge(proposal: proposal, showsProtectionWarning: false)
                Spacer(minLength: 8)
                ProposalStrengthLabel(strength: proposal.strength)
            }

            Text(proposal.kind.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Says plainly what the protection signals changed, rather than leaving the user to infer
    /// it from a badge.
    private var protectionNotice: some View {
        Label {
            Text(
                proposal.isProtected
                    ? "InboxSweep won't propose cleanup for this sender. Anything you preview here will still exclude the messages listed above."
                    : "This signal is weak on its own, so InboxSweep is asking you to look rather than suggesting anything."
            )
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.shield")
        }
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        .accessibilityIdentifier("senderDetail.protectionNotice")
    }
}

/// One reason, with a symbol that says what kind of statement it is.
private struct ReasonRow: View {

    let reason: ProposalReason

    var body: some View {
        Label {
            Text(reason.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbolName: String {
        switch reason.kind {
        case .protection: "exclamationmark.shield"
        case .volume: "tray.full"
        case .providerCategory: "tag"
        case .listMetadata: "envelope.open"
        case .cadence: "clock"
        case .automatedSender: "gearshape"
        case .engagement: "hand.raised"
        case .window: "calendar"
        case .insufficientEvidence: "questionmark.circle"
        }
    }
}

// Previews are development-only, and some of them run on the debug-only sample
// mailbox, so the whole block stays out of release builds.
#if DEBUG
#Preview {
    let messages = SampleMailbox.messages()
    let summaries = SenderAggregator.aggregate(messages)
    let proposals = CleanupProposalEngine.evaluate(summaries: summaries, messages: messages)

    return ScrollView {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(summaries.prefix(4)) { summary in
                if let proposal = proposals[summary.id] {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary.sender.displayValue).font(.headline)
                        ProposalReasoningView(proposal: proposal)
                    }
                }
            }
        }
        .padding(24)
    }
    .frame(width: 420, height: 700)
}
#endif

import SwiftUI

/// Unsubscribe options for one sender: what was found, or why nothing was.
///
/// The screen a sender's **Unsubscribe options…** entry point opens. It is a *reading*, not a
/// confirmation: it shows what the sender's own headers say, and the only thing on it that can
/// lead to an action is a button that opens ``UnsubscribeReviewSheet``, which then asks twice.
///
/// It exists as a separate step because two of the five states have nothing to confirm. A
/// sender with no header and a sender whose header InboxSweep refused both need a screen that
/// explains, and routing them into a confirmation sheet with its buttons disabled would be a
/// worse answer than a sentence.
struct UnsubscribeOptionsSheet: View {

    let session: InboxSessionModel
    let summary: SenderSummary

    @Environment(\.dismiss) private var dismiss

    /// The review the user has opened, if any. Freezing one performs nothing.
    @State private var pendingReview: UnsubscribeReviewSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch opportunity.availability {
                    case .noEvidence, .ambiguousMetadata:
                        unavailable
                    case .oneClickAvailable, .webPageAvailable, .mailHandoffAvailable:
                        available
                    }
                    evidenceSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 600, minHeight: 420, idealHeight: 520)
        .sheet(item: $pendingReview) { review in
            UnsubscribeReviewSheet(session: session, review: review)
        }
    }

    // MARK: - Derived state

    /// Recomputed on every render from the window in memory.
    ///
    /// Cheap, and recomputing is what keeps it honest: there is no stored reading that could
    /// still be showing a sender's metadata from before a deeper load changed it.
    private var opportunity: UnsubscribeOpportunity {
        session.unsubscribeOpportunity(forSenderKey: summary.id)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The screen's identifier sits on the title rather than on the root stack. SwiftUI
            // pushes an identifier down onto every descendant, so a stack-wide one makes every
            // control and every sentence below it unfindable, which is the same lesson
            // `ActivityView` records, learnt again here.
            Text("Unsubscribe options for \(summary.sender.displayValue)")
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .accessibilityIdentifier("unsubscribeOptions.screen")

            Label {
                Text(Self.scopeNote)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("unsubscribeOptions.scopeNote")
            } icon: {
                Image(systemName: "magnifyingglass")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    /// Said before anything else, because it is what makes opening this screen safe.
    static let scopeNote = """
        Opening this sends nothing and changes nothing. InboxSweep is reading what this sender's \
        own message headers say about unsubscribing; nothing happens until you confirm it.
        """

    /// The three states with something to act on.
    private var available: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("What's available") {
                        Text(opportunity.availability.displayName)
                            .accessibilityIdentifier("unsubscribeOptions.availability")
                    }
                    if let mechanism = opportunity.mechanism {
                        LabeledContent("Goes to") {
                            Text(mechanism.destinationHost)
                                .accessibilityIdentifier("unsubscribeOptions.host")
                        }
                        LabeledContent("Performed by") {
                            Text(mechanism.kind.actorDescription)
                        }
                    }
                    LabeledContent("How sure") {
                        Text(opportunity.confidence.displayName)
                    }
                }
                .font(.callout)
                .padding(6)
            }

            if let caution = opportunity.cautionNote {
                Label(caution, systemImage: "shield.lefthalf.filled")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("unsubscribeOptions.caution")
            }

            Label {
                Text(UnsubscribeOpportunity.futureMailNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("unsubscribeOptions.futureMailNote")
            } icon: {
                Image(systemName: "calendar.badge.exclamationmark")
            }
        }
    }

    /// The two states with nothing to act on, each explained rather than left blank.
    @ViewBuilder
    private var unavailable: some View {
        ContentUnavailableView {
            Label(
                opportunity.availability.displayName,
                systemImage: opportunity.availability == .ambiguousMetadata ? "questionmark.circle" : "envelope.badge.shield.half.filled"
            )
        } description: {
            // One identifier, on the sentence, for the reason the header records: putting it on
            // the `ContentUnavailableView` would push it down over the explanation inside.
            Text(opportunity.unavailableExplanation ?? "")
                .accessibilityIdentifier("unsubscribeOptions.unavailable")
        }
    }

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !opportunity.evidence.isEmpty {
                Text("What InboxSweep saw")
                    .font(.headline)

                ForEach(opportunity.evidence) { item in
                    Label {
                        Text(item.explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: item.isCautionary ? "exclamationmark.circle" : "text.magnifyingglass")
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Text(Self.bodyLinkNote)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("unsubscribeOptions.bodyLinkNote")
        }
        .accessibilityIdentifier("unsubscribeOptions.evidence")
    }

    /// The limitation worth stating on the screen rather than only in the docs.
    static let bodyLinkNote = """
        InboxSweep only reads message headers, never message bodies, so an unsubscribe link that \
        lives in the text of an email is one it cannot see. Nothing here is a complete list of a \
        sender's unsubscribe options.
        """

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("unsubscribeOptions.doneButton")

            if opportunity.isActionable {
                Button("Review unsubscribe…") {
                    // Freezes a review. No request, no page, no record; see
                    // ``InboxSessionModel/makeUnsubscribeReview(forSenderKey:using:)``.
                    pendingReview = session.makeUnsubscribeReview(forSenderKey: summary.id)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isUnsubscribing)
                .help("Shows the exact destination and asks you to confirm. Nothing is sent by opening it.")
                .accessibilityIdentifier("unsubscribeOptions.reviewButton")
            }
        }
        .padding(20)
    }
}

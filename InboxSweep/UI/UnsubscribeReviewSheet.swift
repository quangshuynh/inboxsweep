import SwiftUI

/// The unsubscribe review: what is on offer, where it would go, who would do it, and what it
/// cannot be taken back from.
///
/// ### Why this is not the archive sheet with different words
///
/// Requirement 9 of this interval says not to reuse the archive confirmation if that would blur
/// the semantics, and it would. The archive sheet is built around a *list of messages* and ends
/// with an Undo button. Neither exists here: an unsubscribe names no messages, and there is
/// nothing to undo. A user who had learnt that the confirmation sheet always offers a way back
/// would be learning the wrong lesson on the one screen where it is not true.
///
/// So this is its own screen, and the two things it says that the archive sheet never does are
/// the reason it exists:
///
/// - **the exact destination**, printed in full before anything happens;
/// - **that this is about future mail**, and that archiving is not.
///
/// ### Opening it sends nothing
///
/// Everything above the buttons is read out of a frozen ``UnsubscribeReviewSnapshot``, which was
/// copied out of the loaded window when the user asked to look. No request goes out, no page is
/// opened, nothing is recorded, and closing the sheet leaves the world exactly as it was.
struct UnsubscribeReviewSheet: View {

    let session: InboxSessionModel

    /// The frozen review. Constant for the life of this sheet by construction, except when
    /// the user deliberately picks a different mechanism, which freezes a new one.
    @State var review: UnsubscribeReviewSnapshot

    @Environment(\.dismiss) private var dismiss

    /// Set when the user has pressed the confirming button but not yet the one that acts.
    ///
    /// The dedicated confirmation requirement 9 asks for, as a state rather than as an alert:
    /// the destination stays on screen behind it, so the thing being confirmed is visible at the
    /// moment of confirming rather than replaced by a dialog that names it again in fewer words.
    @State private var isConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let activity, activity.outcome != nil || activity.refusal != nil {
                        outcomeSection(activity)
                    } else {
                        destination
                        whatHappens
                        futureMailWarning
                        cautionSection
                        evidenceSection
                        alternativesSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 600)
    }

    // MARK: - Derived state

    /// The activity, but only when it is about *this* confirmation.
    ///
    /// Matched on the frozen review's identifier, so a result left over from another sender's
    /// unsubscribe cannot be read as the outcome of this one.
    private var activity: UnsubscribeActivity? {
        guard let activity = session.unsubscribeActivity, activity.id == review.id else { return nil }
        return activity
    }

    private var isRunning: Bool { activity?.isRunning == true }

    private var opportunity: UnsubscribeOpportunity { review.opportunity }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                // Carries the screen's identifier as well as its own, for the reason
                // ``UnsubscribeOptionsSheet`` records: an identifier on the root stack would be
                // pushed down onto every descendant and make the destination, the evidence, and
                // both buttons unfindable.
                Text(headline)
                    .accessibilityIdentifier("unsubscribeSheet.screen")
            } icon: {
                Image(systemName: headlineSymbol)
            }
            .font(.title3.weight(.semibold))
            .lineLimit(3)

            Text(subhead)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var headline: String {
        if let activity, !activity.isRunning { return activity.headline }
        if isRunning { return activity?.progressDescription ?? "Working…" }
        return "Unsubscribe from \(review.senderDisplayValue)?"
    }

    private var headlineSymbol: String {
        if let outcome = activity?.outcome { return outcome.symbolName }
        if activity?.refusal != nil { return "exclamationmark.triangle" }
        if isRunning { return "arrow.triangle.2.circlepath" }
        return review.mechanismKind.symbolName
    }

    private var subhead: String {
        if let activity, !activity.isRunning { return activity.explanation }
        if let activity, activity.isRunning { return activity.progressDescription }
        return review.mechanism.actionDescription
    }

    /// The exact destination. The single most important thing on this screen.
    private var destination: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Mechanism") {
                    Text(review.mechanismKind.displayName)
                        .accessibilityIdentifier("unsubscribeSheet.mechanism")
                }
                LabeledContent("Performed by") {
                    Text(review.mechanismKind.actorDescription)
                }
                LabeledContent(review.mechanismKind == .mail ? "Address" : "Destination") {
                    // Selectable, and shown in full rather than truncated to a host. A user who
                    // wants to check where this goes is entitled to the whole string, and a
                    // shortened one would be InboxSweep deciding which part matters.
                    Text(review.destinationDescription)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("unsubscribeSheet.destination")
                }
                LabeledContent(review.mechanismKind == .mail ? "Mail domain" : "Host") {
                    Text(review.destinationHost)
                        .accessibilityIdentifier("unsubscribeSheet.destinationHost")
                }
                LabeledContent("How sure") {
                    Text(opportunity.confidence.displayName)
                        .accessibilityIdentifier("unsubscribeSheet.confidence")
                }
            }
            .font(.callout)
            .padding(6)
        }
        .accessibilityIdentifier("unsubscribeSheet.destinationBox")
    }

    /// What confirming does, point by point.
    private var whatHappens: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What this does")
                .font(.headline)

            switch review.mechanismKind {
            case .oneClick:
                point("paperplane", "Sends one request to \(review.destinationHost), in the format the unsubscribe standard defines.")
                point("lock.slash", "Sends nothing about you or your mailbox with it: no address, no message, no Google sign-in.")
                point("arrow.triangle.branch", "Follows at most \(UnsubscribeRedirectPolicy.maximumRedirects) redirects, https only, and refuses to be sent anywhere unencrypted.")
                point("arrow.clockwise", "Sends it once. InboxSweep never retries an unsubscribe on its own.")
            case .webPage:
                point("safari", "Opens \(review.destinationHost) in your browser, and stops there.")
                point("hand.raised", "Doesn't read the page, fill anything in, submit anything, or sign you in.")
                point("person", "Anything the page asks for, a confirmation or a login, is yours to do or not.")
            case .mail:
                point("envelope", "Opens a new message to \(review.destinationHost) in your mail app, already addressed.")
                point("paperplane.slash", "Does not send it. InboxSweep has no permission to send mail and no way to.")
                point("person", "You send it, or you close it.")
            }

            point("tray", UnsubscribeReviewSnapshot.boundaryNote)
        }
        .accessibilityIdentifier("unsubscribeSheet.whatHappens")
    }

    /// The difference from archiving, stated where the decision is made.
    private var futureMailWarning: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("This is about mail you haven't received yet")
                    .font(.callout.weight(.medium))
                Text(UnsubscribeReviewSnapshot.futureMailNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("unsubscribeSheet.futureMailNote")
            }
        } icon: {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The tone change for a sender whose mail looks like something the user may need.
    ///
    /// Present only when there are protection signals, and it blocks nothing: it says what was
    /// noticed and leaves the decision where it belongs.
    @ViewBuilder
    private var cautionSection: some View {
        if let caution = opportunity.cautionNote {
            Label {
                Text(caution)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("unsubscribeSheet.caution")
            } icon: {
                Image(systemName: "shield.lefthalf.filled")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Why InboxSweep thinks there is an unsubscribe here at all.
    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why InboxSweep is showing you this")
                .font(.headline)

            Text(opportunity.confidence.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(opportunity.evidence) { item in
                Label {
                    Text(item.explanation)
                        .font(.callout)
                        .foregroundStyle(item.isCautionary ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: item.isCautionary ? "exclamationmark.circle" : "text.magnifyingglass")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityIdentifier("unsubscribeSheet.evidence")
    }

    /// The other mechanisms this sender offers, and how to use one instead.
    ///
    /// Listed rather than hidden. A sheet that silently picked one of three would be making the
    /// user's decision for them under the name of simplifying it.
    @ViewBuilder
    private var alternativesSection: some View {
        if !review.alternatives.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Other ways this sender offers")
                    .font(.headline)

                if let rationale = opportunity.selection?.selectionRationale {
                    Text(rationale)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("unsubscribeSheet.selectionRationale")
                }

                ForEach(Array(review.alternatives.enumerated()), id: \.offset) { _, alternative in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: alternative.kind.symbolName)
                            .foregroundStyle(.tertiary)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(alternative.kind.displayName)
                                .font(.callout.weight(.medium))
                            Text(alternative.destinationDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 8)

                        Button("Use this instead") { choose(alternative) }
                            .disabled(isRunning)
                            .help("Switches this review to that mechanism. Nothing is sent, and you still confirm.")
                    }
                }
            }
            .accessibilityIdentifier("unsubscribeSheet.alternatives")
        }
    }

    /// The result, once there is one.
    private func outcomeSection(_ activity: UnsubscribeActivity) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let warning = activity.localRecordWarning {
                Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("unsubscribeSheet.recordWarning")
            }

            if activity.outcome?.didWhatWasAsked == true {
                Label {
                    Text(UnsubscribeActivityEntry.cannotConfirmNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("unsubscribeSheet.cannotConfirmNote")
                } icon: {
                    Image(systemName: "questionmark.circle")
                }

                Label {
                    Text(UnsubscribeActivityEntry.noUndoNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("unsubscribeSheet.noUndoNote")
                } icon: {
                    Image(systemName: "arrow.uturn.backward.slash")
                }
            }

            // Carries the section's identifier, rather than the stack doing so: a stack-wide
            // identifier is pushed down onto every descendant and would take the two caveats
            // above with it. This line is present in every outcome, so it is the one to mark.
            Text(UnsubscribeReviewSnapshot.boundaryNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("unsubscribeSheet.outcome")
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 18)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if isConfirming, activity == nil {
                Label(confirmationPrompt, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("unsubscribeSheet.confirmPrompt")
            }

            Spacer(minLength: 12)

            if let activity, !activity.isRunning {
                finishedButtons(activity)
            } else if isRunning {
                Button(actionVerb) {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                    .accessibilityIdentifier("unsubscribeSheet.actionButton")
            } else {
                Button(isConfirming ? "Not now" : "Cancel") {
                    // Cancelling at either step leaves the world untouched: nothing has been
                    // sent at this point in either case.
                    if isConfirming { isConfirming = false } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("unsubscribeSheet.cancelButton")

                if isConfirming {
                    Button(confirmVerb) { session.confirmUnsubscribe(review) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!session.canPerform(review))
                        .accessibilityIdentifier("unsubscribeSheet.confirmButton")
                } else {
                    // Deliberately *not* the default action: no keyboard shortcut arms this, so
                    // a stray Return on the sheet cannot begin an unsubscribe.
                    Button(actionVerb) { isConfirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!session.canPerform(review))
                        .help("Asks you to confirm once more, then \(review.mechanismKind.actorDescription.lowercased()).")
                        .accessibilityIdentifier("unsubscribeSheet.actionButton")
                }
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func finishedButtons(_ activity: UnsubscribeActivity) -> some View {
        if activity.failure?.isWorthOfferingAgain == true, session.canPerform(review) {
            // An explicit second attempt by the user, which is the only kind there is: nothing
            // in the app retries an unsubscribe by itself.
            Button("Try again") { session.confirmUnsubscribe(review) }
                .accessibilityIdentifier("unsubscribeSheet.retryButton")
        }

        Button("Done") {
            session.dismissUnsubscribeActivity()
            dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("unsubscribeSheet.doneButton")
    }

    /// The first button: opens the confirmation step and does nothing else.
    private var actionVerb: String {
        switch review.mechanismKind {
        case .oneClick: "Send unsubscribe request…"
        case .webPage: "Open unsubscribe page…"
        case .mail: "Open email unsubscribe…"
        }
    }

    /// The second button: the one that acts.
    private var confirmVerb: String {
        switch review.mechanismKind {
        case .oneClick: "Send the request"
        case .webPage: "Open in browser"
        case .mail: "Open in mail app"
        }
    }

    private var confirmationPrompt: String {
        switch review.mechanismKind {
        case .oneClick:
            "InboxSweep will send one unsubscribe request to \(review.destinationHost). This can't be undone."
        case .webPage:
            "InboxSweep will open \(review.destinationHost) in your browser."
        case .mail:
            "InboxSweep will open an unsubscribe message to \(review.destinationHost). It won't send it."
        }
    }

    /// Switches this review to another mechanism the same sender offered.
    ///
    /// Re-freezes rather than mutating: the new snapshot carries a new identifier, so a
    /// confirmation already spent on the previous mechanism cannot be reused for this one.
    private func choose(_ mechanism: UnsubscribeMechanism) {
        guard let refrozen = session.makeUnsubscribeReview(forSenderKey: review.senderKey, using: mechanism)
        else { return }
        isConfirming = false
        review = refrozen
    }
}

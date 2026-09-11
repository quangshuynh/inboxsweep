import Foundation

/// One unsubscribe action, as the screen showing it needs to understand it.
///
/// The unsubscribe counterpart of ``MessageMutationActivity``, and a separate type rather than
/// a case added to it. The two describe different things: an archive has a per-message receipt,
/// a partial outcome, a progress count, and an undo; an unsubscribe has one destination, one
/// answer, and no way back. Merging them would have meant a type where half the properties were
/// meaningless for half the values.
nonisolated struct UnsubscribeActivity: Equatable, Sendable, Identifiable {

    /// The frozen review's identifier, shared with the request and the recorded entry.
    let id: UUID

    let senderKey: SenderSummary.ID
    let senderDisplayValue: String
    let mechanismKind: UnsubscribeMechanism.Kind

    /// The destination, for the screen to keep showing while the request is out.
    let destinationHost: String

    /// The account it was reviewed under. Shown nowhere; kept so a result cannot be read
    /// against a window that has since changed accounts.
    let accountAddress: String

    private(set) var phase: Phase

    init(
        id: UUID,
        senderKey: SenderSummary.ID,
        senderDisplayValue: String,
        mechanismKind: UnsubscribeMechanism.Kind,
        destinationHost: String,
        accountAddress: String,
        phase: Phase = .running
    ) {
        self.id = id
        self.senderKey = senderKey
        self.senderDisplayValue = senderDisplayValue
        self.mechanismKind = mechanismKind
        self.destinationHost = destinationHost
        self.accountAddress = accountAddress
        self.phase = phase
    }

    nonisolated enum Phase: Equatable, Sendable {

        /// The request is out, or the handoff is being made. Nothing is claimed yet.
        case running

        /// There is an answer. Which is not the same as there being a result — see
        /// ``UnsubscribeOutcome``.
        ///
        /// `localRecordWarning` carries the one awkward case: the action really happened and
        /// this Mac could not write it down. Carried on the *finished* case, because reporting
        /// it as a failure would tell the user the opposite of what happened.
        case finished(UnsubscribeOutcome, localRecordWarning: String?)

        /// Refused before anything went out, so nothing was attempted at all.
        ///
        /// Distinct from a finished action that failed: there, somebody was contacted and said
        /// no; here, nobody was contacted. Only the second is safe to describe as "nothing left
        /// this Mac".
        case refused(UnsubscribeFailure)
    }

    var isRunning: Bool { phase == .running }

    var outcome: UnsubscribeOutcome? {
        if case .finished(let outcome, _) = phase { return outcome }
        return nil
    }

    var refusal: UnsubscribeFailure? {
        if case .refused(let failure) = phase { return failure }
        return nil
    }

    /// The failure to lead with, from either phase.
    var failure: UnsubscribeFailure? { refusal ?? outcome?.failure }

    var localRecordWarning: String? {
        if case .finished(_, let warning) = phase { return warning }
        return nil
    }

    /// Whether InboxSweep did the thing that was asked of it.
    var didWhatWasAsked: Bool { outcome?.didWhatWasAsked == true }

    func settingPhase(_ phase: Phase) -> UnsubscribeActivity {
        UnsubscribeActivity(
            id: id,
            senderKey: senderKey,
            senderDisplayValue: senderDisplayValue,
            mechanismKind: mechanismKind,
            destinationHost: destinationHost,
            accountAddress: accountAddress,
            phase: phase
        )
    }

    // MARK: - Wording

    /// What is shown while it is happening.
    var progressDescription: String {
        switch mechanismKind {
        case .oneClick:
            "Sending one unsubscribe request to \(destinationHost). Waiting for an answer…"
        case .webPage:
            "Opening \(destinationHost) in your browser…"
        case .mail:
            "Opening a message to \(destinationHost) in your mail app…"
        }
    }

    /// The headline once there is an answer.
    var headline: String {
        switch phase {
        case .running: progressDescription
        case .refused(let failure): failure.headline
        case .finished(let outcome, _): outcome.headline
        }
    }

    /// The sentence under it.
    var explanation: String {
        switch phase {
        case .running: progressDescription
        case .refused(let failure): failure.explanation
        case .finished(let outcome, _): outcome.explanation
        }
    }
}

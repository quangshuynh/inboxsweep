import Foundation

/// A frozen set of messages the user picked, named individually, for one account.
///
/// This is the *set* form of ``MailArchiveRequest``, and it is deliberately shaped the same way:
/// a list of provider message identifiers and the account they belong to, and nothing else.
/// There is no label parameter, no sender key, no query, no action, and no plan, so the only
/// thing this type can express is "these exact messages", which is what makes a set archive
/// checkable against what the user confirmed.
///
/// ### Frozen means frozen
///
/// The identifiers are captured once, deduplicated once, ordered once, and never change. A
/// selection built while one window was on screen describes that window's messages forever; if
/// the mailbox moves underneath it the operation is refused and re-reviewed, rather than
/// silently acting on a different set. ``InboxSessionModel`` re-validates every identifier in
/// here against the live window immediately before execution for exactly that reason.
///
/// Constructing one is free and sends nothing. It is a description of an intent, not an
/// instruction: the only thing that executes it is an explicit confirmation.
nonisolated struct MailArchiveSelection: Hashable, Sendable {

    /// The messages to act on: deduplicated, in the order the user's screen listed them.
    ///
    /// Order is preserved rather than sorted so the per-message results line up with the list
    /// the user confirmed. Duplicates are removed at construction because a set that named the
    /// same message twice would send two requests and count two outcomes for one message.
    let messageIDs: [MailMessageID]

    /// The address of the account every message was loaded from.
    ///
    /// Carried for the same reason ``MailArchiveRequest`` carries it: the boundary re-checks
    /// this rather than trusting the caller, so a selection assembled for one mailbox can never
    /// be executed against another.
    let accountAddress: String

    /// Identifies this *logical* set mutation.
    ///
    /// Stable across a repeated submission of the same confirmation, and reused as the
    /// identifier of the durable ``MailMutationTransaction`` the operation writes, so one
    /// confirmation is one transaction however many times its button is pressed.
    let operationID: UUID

    /// Builds a selection, or `nil` when there is nothing to act on.
    ///
    /// Failable rather than permitting an empty set: "archive nothing" is not an operation, and
    /// a boundary that accepted it would have a code path where confirming does nothing and
    /// reports success.
    init?(messageIDs: [MailMessageID], accountAddress: String, operationID: UUID = UUID()) {
        var seen = Set<MailMessageID>()
        let deduplicated = messageIDs.filter { seen.insert($0).inserted }
        guard !deduplicated.isEmpty else { return nil }

        self.messageIDs = deduplicated
        self.accountAddress = accountAddress
        self.operationID = operationID
    }

    var count: Int { messageIDs.count }

    /// The per-message request for one member of the set.
    ///
    /// Every message in a set goes through the same ``MailArchiveRequest`` a single archive
    /// does, same type, same fields, same validation at the boundary. That is the whole of the
    /// generalization: a set is a sequence of the proven single-message call, not a second way
    /// to reach Gmail.
    ///
    /// The requests share this selection's ``operationID`` because they are one logical
    /// mutation. The provider ignores it; the local transaction is what it names.
    func request(for messageID: MailMessageID) -> MailArchiveRequest {
        MailArchiveRequest(
            messageID: messageID,
            accountAddress: accountAddress,
            operationID: operationID
        )
    }
}

/// What happened to one message in a set.
///
/// Per-message rather than per-operation because that is the difference between "the archive
/// failed" and "eight of your ten messages were archived". A set of twelve where four fail is
/// eight real changes to somebody's mailbox, and reporting it as a failure would be telling
/// them the opposite of what happened to eight of their messages.
nonisolated enum MailMessageMutationOutcome: Hashable, Sendable {

    /// The provider confirmed the change, and reported these labels afterwards.
    ///
    /// Carries the labels rather than a Boolean so local reconciliation says what the mailbox
    /// says, exactly as it does for a single message.
    case confirmed(labelsAfterMutation: Set<MailLabel>)

    /// The provider was asked and refused. The message is unchanged.
    case failed(MailMutationError)

    /// No request was ever sent for this message.
    ///
    /// Distinct from ``failed(_:)`` because the recoveries differ and the honesty differs: a
    /// message that was never asked about is in a knowably unchanged state, and the user can be
    /// offered it again without wondering what the provider did with it.
    case notAttempted(MailMutationError)

    var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }

    var wasAttempted: Bool {
        if case .notAttempted = self { return false }
        return true
    }

    /// The failure, for a message that has one.
    var error: MailMutationError? {
        switch self {
        case .confirmed: nil
        case .failed(let error), .notAttempted(let error): error
        }
    }

    var labelsAfterMutation: Set<MailLabel>? {
        if case .confirmed(let labels) = self { return labels }
        return nil
    }
}

/// One message's line in a set's result.
nonisolated struct MailMessageMutationResult: Hashable, Sendable, Identifiable {

    let messageID: MailMessageID
    let outcome: MailMessageMutationOutcome

    var id: MailMessageID { messageID }
}

/// What a whole set mutation did, message by message.
///
/// Returned rather than thrown, even when every message failed. A set operation does not have
/// one outcome (it has as many outcomes as it had messages) and a thrown error would have to
/// discard the confirmed ones to be thrown at all.
nonisolated struct MailArchiveSetReceipt: Hashable, Sendable {

    /// The logical mutation this is the result of, matching the selection's operation ID.
    let operationID: UUID

    let operation: MailMutationOperation

    /// The account it was performed against.
    let accountAddress: String

    /// One result per requested message, in the selection's order.
    let results: [MailMessageMutationResult]

    init(
        operationID: UUID,
        operation: MailMutationOperation,
        accountAddress: String,
        results: [MailMessageMutationResult]
    ) {
        self.operationID = operationID
        self.operation = operation
        self.accountAddress = accountAddress
        self.results = results
    }

    /// A receipt in which nothing was attempted, for a refusal that never reached the provider.
    static func refused(
        _ selection: MailArchiveSelection,
        operation: MailMutationOperation,
        because error: MailMutationError
    ) -> MailArchiveSetReceipt {
        MailArchiveSetReceipt(
            operationID: selection.operationID,
            operation: operation,
            accountAddress: selection.accountAddress,
            results: selection.messageIDs.map {
                MailMessageMutationResult(messageID: $0, outcome: .notAttempted(error))
            }
        )
    }

    // MARK: - Partitions

    /// The messages the provider confirmed, in the selection's order.
    ///
    /// **The only messages a set is allowed to reconcile locally, and the only ones an undo may
    /// name.** Everything else in the app that asks "what actually changed?" asks this.
    var confirmedMessageIDs: [MailMessageID] {
        results.filter { $0.outcome.isConfirmed }.map(\.messageID)
    }

    /// The messages that were asked about and refused, with the reason for each.
    var failures: [MailMessageMutationResult] {
        results.filter { if case .failed = $0.outcome { return true } else { return false } }
    }

    /// The messages no request was ever sent for.
    var notAttempted: [MailMessageMutationResult] {
        results.filter { !$0.outcome.wasAttempted }
    }

    var selectedCount: Int { results.count }
    var confirmedCount: Int { confirmedMessageIDs.count }
    var failedCount: Int { failures.count }
    var notAttemptedCount: Int { notAttempted.count }

    /// Every message did what was asked.
    var isCompleteSuccess: Bool { confirmedCount == selectedCount && selectedCount > 0 }

    /// Some changed and some did not: the case this whole type exists for.
    var isPartialSuccess: Bool { confirmedCount > 0 && confirmedCount < selectedCount }

    /// Nothing changed.
    var isCompleteFailure: Bool { confirmedCount == 0 }

    /// The single error to lead with when nothing succeeded.
    ///
    /// `nil` whenever anything was confirmed: a run that changed the mailbox does not have "an
    /// error", it has a list of outcomes, and collapsing it to one would lose the successes.
    var leadingFailure: MailMutationError? {
        guard isCompleteFailure else { return nil }
        return results.compactMap(\.outcome.error).first
    }

    /// The labels the provider reported for each confirmed message.
    var confirmedLabels: [MailMessageID: Set<MailLabel>] {
        var labels: [MailMessageID: Set<MailLabel>] = [:]
        for result in results {
            if let confirmed = result.outcome.labelsAfterMutation {
                labels[result.messageID] = confirmed
            }
        }
        return labels
    }
}

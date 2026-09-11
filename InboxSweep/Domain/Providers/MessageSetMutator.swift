import Foundation

/// Runs one confirmed set of messages through the single-message mutation boundary, and reports
/// what happened to each of them.
///
/// ### Why this is not a new provider capability
///
/// ``MailMessageArchiving`` is unchanged by this interval: still four methods, still one message
/// per call, still inbox membership only. A set archive is *this type* calling that boundary
/// once per message. Nothing new is remotely reachable, because there is nothing new to reach —
/// every request a set produces is the same `MailArchiveRequest` a single archive produces, and
/// the provider cannot tell the two apart.
///
/// That is what makes the safety claim from the previous interval survive intact: "the app can
/// add or remove `INBOX` on one named message" is still the whole vocabulary. A set just says it
/// more than once.
///
/// ### Why sequential, and not Gmail's batch endpoint
///
/// Gmail publishes `users.messages.batchModify`, which would apply one label change to up to a
/// thousand messages in a single request. It is **not** used here, and performance was not the
/// deciding question:
///
/// - `batchModify` returns `204 No Content`. It reports no per-message result and does not echo
///   the messages back, so there would be nothing to reconcile local state *against* — the app
///   would be reduced to assuming the change it asked for is the change that happened, which is
///   precisely the assumption every other write in this app refuses to make.
/// - A partial failure inside a batch is not expressible in its reply. "Eight of your twelve
///   were archived" could not be said, and saying it is the point of this interval.
/// - One request naming a thousand identifiers is a larger blast radius per mistake than one
///   request naming one. A bug in set construction costs one wrong message here, not all of
///   them.
///
/// So each message is its own `messages.modify` — the exact call archiving has used since it
/// existed, already proven, already idempotent, already echoing the message back.
///
/// ### Strictly one request at a time
///
/// No parallelism at all. Concurrency would buy latency on large sets and cost the two things
/// worth more: honest cancellation (with one request in flight, "stop" means at most one more
/// message changes) and a bounded footprint on somebody's Gmail quota. `SafetyBoundaryTests`
/// asserts that two requests are never in flight together, so this is a property rather than an
/// implementation detail.
nonisolated struct MessageSetMutator: Sendable {

    private let archiver: any MailMessageArchiving

    init(archiver: any MailMessageArchiving) {
        self.archiver = archiver
    }

    /// Applies `operation` to every message in `selection`, one request at a time.
    ///
    /// Never throws. A set does not have a single outcome, and throwing would mean discarding
    /// the messages that really were changed in order to report the ones that were not.
    ///
    /// - Parameter onMessageCompleted: Called after each message is resolved, with how many of
    ///   the selection have been resolved so far. Progress only — it cannot influence the run.
    func perform(
        _ operation: MailMutationOperation,
        _ selection: MailArchiveSelection,
        onMessageCompleted: (@Sendable (Int) async -> Void)? = nil
    ) async -> MailArchiveSetReceipt {
        var results: [MailMessageMutationResult] = []
        results.reserveCapacity(selection.count)

        /// Set once a failure means every remaining message would fail the same way.
        var abandonedBecause: MailMutationError?

        for messageID in selection.messageIDs {
            if let abandonedBecause {
                results.append(MailMessageMutationResult(messageID: messageID, outcome: .notAttempted(abandonedBecause)))
                continue
            }

            // Checked before the request rather than after it. Once a request is with the
            // provider it may already have been applied, so cancellation can only honestly
            // promise "no *further* messages will be changed" — which is what this is.
            if Task.isCancelled {
                abandonedBecause = .cancelled
                results.append(MailMessageMutationResult(messageID: messageID, outcome: .notAttempted(.cancelled)))
                continue
            }

            let outcome = await apply(operation, selection.request(for: messageID))
            results.append(MailMessageMutationResult(messageID: messageID, outcome: outcome))

            // A failure about the *session* — a withdrawn grant, a swapped account — is not a
            // fact about this message, and the next eleven requests would fail identically.
            // Sending them anyway would be eleven pointless writes against somebody's quota.
            if let error = outcome.error, error.endsTheRun {
                abandonedBecause = error
            }

            await onMessageCompleted?(results.count)
        }

        return MailArchiveSetReceipt(
            operationID: selection.operationID,
            operation: operation,
            accountAddress: selection.accountAddress,
            results: results
        )
    }

    /// One message, through the boundary that has always performed one message.
    ///
    /// No retry loop of its own. The Gmail client already retries the failures worth retrying
    /// (throttling, transient 5xx, a dropped connection) inside a single `modify`, and a second
    /// retry layer here would multiply the request count for a large set without making any
    /// individual message more likely to succeed. A message that failed for a retryable reason
    /// is reported as such, and the user is offered those messages again.
    private func apply(
        _ operation: MailMutationOperation,
        _ request: MailArchiveRequest
    ) async -> MailMessageMutationOutcome {
        do {
            let receipt = operation == .archive
                ? try await archiver.archive(request)
                : try await archiver.restoreToInbox(request)

            // The boundary already checks this, and it is checked again here because a receipt
            // about a different message must never be written into this message's row.
            guard receipt.messageID == request.messageID else {
                return .failed(.rejectedByProvider(
                    reason: "Gmail replied about a different message than the one InboxSweep asked about."
                ))
            }
            return .confirmed(labelsAfterMutation: receipt.labelsAfterMutation)
        } catch {
            return .failed(.wrapping(error))
        }
    }
}

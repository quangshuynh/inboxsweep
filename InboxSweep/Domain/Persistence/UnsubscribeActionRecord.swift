import Foundation

/// One unsubscribe action InboxSweep performed, written down.
///
/// ### Why this is not a ``MailMutationTransaction``
///
/// Requirement 16 of this interval says not to force unsubscribe into an archive-shaped record
/// if that makes the semantics dishonest, and it would. A transaction names messages, counts
/// how many of them a provider confirmed, and carries an undo state — three fields that are
/// either meaningless or actively misleading here. An unsubscribe names no messages. It
/// confirms nothing about a mailbox. And it has **no undo**: there is no standards-based
/// inverse of a one-click unsubscribe, and a resubscribe button would be a fabrication.
///
/// So the archive history keeps the shape it has, entry for entry, and this is a second kind of
/// entry in the same file. Existing records are not rewritten, migrated, or reinterpreted —
/// which is what keeps the v2 and v3 guarantees the transaction store documents intact.
///
/// ### What ends up on disk
///
/// An identifier, an account address, which mechanism was used, the destination **host**, an
/// outcome, a timestamp, and — when there was one — the message whose headers it came from.
///
/// The host is the one field worth arguing about, because it is third-party metadata derived
/// from mail. It is kept because without it this file cannot answer the question it exists to
/// answer: "what did InboxSweep do?" is not answered by "it sent an unsubscribe request"
/// without saying to whom. Note what is *not* kept: no full URL with its per-recipient token, no
/// mailto address, no subject, no sender display name, no list identifier. The sender shown on
/// the Activity row is resolved dynamically from the mailbox cache through
/// ``sourceMessageID``, exactly as archive history resolves its messages — so the address is
/// not copied into a second file for the sake of a nicer row.
nonisolated struct UnsubscribeActionRecord: Identifiable, Hashable, Sendable {

    /// The confirmation this action was. Shared with the review snapshot and the request, so a
    /// repeated completion replaces one entry rather than appending a second.
    let id: UUID

    /// The account it was performed under, so an entry can never be read back beside a
    /// different mailbox.
    let accountAddress: String

    /// Which mechanism was used.
    let mechanism: UnsubscribeMechanism.Kind

    /// What happened, in the app's own careful vocabulary.
    let outcome: UnsubscribeOutcome.Kind

    /// The host or mail domain contacted or opened.
    ///
    /// Host only — never the path, never the query. An unsubscribe URL's path is frequently a
    /// per-recipient token, and there is no reason for one to be on disk after the request that
    /// used it has been sent.
    let destinationHost: String

    /// The HTTP status, when there was an HTTP request. `nil` for a handoff.
    let statusCode: Int?

    /// The message whose headers named the destination, when one is known.
    ///
    /// Kept so the Activity row can resolve the sender from the mailbox cache rather than
    /// storing it here.
    let sourceMessageID: MailMessageID?

    /// When it happened.
    let occurredAt: Date

    init(
        id: UUID,
        accountAddress: String,
        mechanism: UnsubscribeMechanism.Kind,
        outcome: UnsubscribeOutcome.Kind,
        destinationHost: String,
        statusCode: Int? = nil,
        sourceMessageID: MailMessageID? = nil,
        occurredAt: Date
    ) {
        self.id = id
        self.accountAddress = accountAddress
        self.mechanism = mechanism
        self.outcome = outcome
        self.destinationHost = destinationHost
        self.statusCode = statusCode
        self.sourceMessageID = sourceMessageID
        self.occurredAt = occurredAt
    }

    /// The record a finished action produces.
    ///
    /// Records failures as well as successes. "InboxSweep tried to unsubscribe you from this
    /// and the endpoint refused" is a fact about what the app did, and a history that kept only
    /// the successes would be a worse answer than none.
    static func completing(
        _ snapshot: UnsubscribeReviewSnapshot,
        outcome: UnsubscribeOutcome,
        at occurredAt: Date
    ) -> UnsubscribeActionRecord {
        UnsubscribeActionRecord(
            id: snapshot.id,
            accountAddress: snapshot.accountAddress,
            mechanism: snapshot.mechanismKind,
            outcome: outcome.kind,
            destinationHost: snapshot.destinationHost,
            statusCode: Self.statusCode(of: outcome),
            sourceMessageID: snapshot.sourceMessageID,
            occurredAt: occurredAt
        )
    }

    private static func statusCode(of outcome: UnsubscribeOutcome) -> Int? {
        switch outcome {
        case .requestAccepted(_, let status), .requestSent(_, let status):
            return status
        case .requestFailed(.rejectedByEndpoint(_, let status)):
            return status
        default:
            return nil
        }
    }

    // MARK: - Derived

    /// Whether this entry records something that actually left this Mac.
    var reachedSomebody: Bool {
        switch outcome {
        case .requestAccepted, .requestSent, .browserOpened, .mailClientOpened: true
        case .requestFailed, .handoffFailed, .unsupportedMechanism, .invalidMetadata: false
        }
    }

    /// Unsubscribes are never undoable, and this is here to say so in code.
    ///
    /// There is no standards-based inverse — no "re-subscribe" request RFC 8058 defines, no
    /// header that names one, nothing a sender is obliged to honour. A button offering to
    /// reverse this would be offering something the app cannot do, and the honest thing is the
    /// constant below.
    var isUndoable: Bool { false }
}

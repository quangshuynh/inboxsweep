import Foundation

/// Exactly what an unsubscribe confirmation is about, captured once and never updated.
///
/// The same idea as ``ArchiveSelectionSnapshot``, for a sharper reason. An archive confirmation
/// that drifted would archive a different set of messages than the one on screen; an
/// unsubscribe confirmation that drifted would send a request **to a different host** than the
/// one the user read, which is the single worst thing this feature could do. So the mechanism,
/// the destination, and the account are frozen here when the review opens, and the session
/// refuses to act if the window no longer agrees with them rather than acting on whatever the
/// metadata says by then.
///
/// **The destination on screen is the destination that gets contacted, or nothing is.**
nonisolated struct UnsubscribeReviewSnapshot: Identifiable, Equatable, Sendable {

    /// The logical action this confirmation would become.
    ///
    /// One confirmation is one identifier, carried into the request and into the recorded
    /// entry, which is what makes a repeated press recognisably the same action rather than a
    /// second request to somebody's server.
    let id: UUID

    /// The account the metadata was read from.
    let accountAddress: String

    /// The sender the metadata came from.
    let senderKey: SenderSummary.ID

    /// The sender, worded as the screens display it.
    let senderDisplayValue: String

    /// The message whose headers produced the mechanism.
    ///
    /// Carried so the staleness check can re-read *that message's* metadata rather than
    /// re-deriving a mechanism for the sender and hoping it matches. A sender rotating
    /// endpoints between one page of mail and the next is ordinary; silently switching which
    /// endpoint a confirmed action contacts would not be.
    let sourceMessageID: MailMessageID?

    /// Which part of the mailbox was loaded when this was frozen.
    let scope: MailboxScope

    /// The full reading, so the sheet can show evidence and confidence without re-deriving them.
    let opportunity: UnsubscribeOpportunity

    /// The mechanism the confirmation would act on.
    let mechanism: UnsubscribeMechanism

    /// When it was frozen.
    let frozenAt: Date

    init(
        id: UUID = UUID(),
        accountAddress: String,
        senderKey: SenderSummary.ID,
        senderDisplayValue: String,
        sourceMessageID: MailMessageID?,
        scope: MailboxScope,
        opportunity: UnsubscribeOpportunity,
        mechanism: UnsubscribeMechanism,
        frozenAt: Date
    ) {
        self.id = id
        self.accountAddress = accountAddress
        self.senderKey = senderKey
        self.senderDisplayValue = senderDisplayValue
        self.sourceMessageID = sourceMessageID
        self.scope = scope
        self.opportunity = opportunity
        self.mechanism = mechanism
        self.frozenAt = frozenAt
    }

    // MARK: - Derived

    var mechanismKind: UnsubscribeMechanism.Kind { mechanism.kind }

    /// The exact destination, as the sheet must print it before anything happens.
    var destinationDescription: String { mechanism.destinationDescription }

    var destinationHost: String { mechanism.destinationHost }

    /// Every mechanism this sender offered, chosen one first.
    var alternatives: [UnsubscribeMechanism] { opportunity.selection?.alternatives ?? [] }

    /// Whether confirming makes InboxSweep itself contact the sender's server.
    var isPerformedByInboxSweep: Bool { mechanism.kind.isPerformedByInboxSweep }

    /// The same snapshot aimed at a different mechanism the sender also offered.
    ///
    /// A **new identifier** each time, deliberately. Switching from the one-click endpoint to
    /// the web page is a different decision about a different destination, and letting it
    /// inherit the old identifier would let a confirmation the user had already spent be reused
    /// for a request they had not.
    func choosing(_ mechanism: UnsubscribeMechanism, at date: Date) -> UnsubscribeReviewSnapshot {
        UnsubscribeReviewSnapshot(
            accountAddress: accountAddress,
            senderKey: senderKey,
            senderDisplayValue: senderDisplayValue,
            sourceMessageID: sourceMessageID,
            scope: scope,
            opportunity: opportunity,
            mechanism: mechanism,
            frozenAt: date
        )
    }

    /// The one-click request this snapshot would send, when that is what it names.
    ///
    /// `nil` for every other mechanism, so there is no way to build a one-click request out of
    /// a review that was not about one.
    func oneClickRequest() -> OneClickUnsubscribeRequest? {
        guard case .oneClick(let endpoint) = mechanism else { return nil }
        return OneClickUnsubscribeRequest(
            endpoint: endpoint,
            accountAddress: accountAddress,
            operationID: id
        )
    }

    /// The URL a handoff would open, when this is a handoff.
    func handoffURL() -> URL? {
        switch mechanism {
        case .oneClick: nil
        case .webPage(let url): url.url
        case .mail(let address): address.composeURL
        }
    }

    /// The sentence that keeps unsubscribing from reading like archiving.
    ///
    /// Held on the snapshot rather than in a view, for the same reason
    /// ``ArchiveSelectionSnapshot/senderScopeNote`` is: it is a promise about the frozen action,
    /// a test can read it without a main-actor hop, and every screen that makes the promise
    /// makes it in identical words.
    static let futureMailNote = UnsubscribeOpportunity.futureMailNote

    /// What confirming will *not* do, which is most of what somebody needs to know.
    static let boundaryNote = """
        No message in your mailbox changes. InboxSweep doesn't archive, delete, move, or mark \
        anything as part of this, and it creates no rule and no Gmail filter.
        """
}

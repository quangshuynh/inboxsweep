import Foundation

/// The exact set of messages a confirmation is about, captured once and never updated.
///
/// ### Why this exists at all
///
/// The single-message confirmation could get away with holding a ``MailMessage`` and letting the
/// session re-check one identifier. A set cannot. Between opening a confirmation for twelve
/// messages and pressing the button, a background page can land, a scope can change, a deep load
/// can finish, and the review list underneath can be a different list. A confirmation wired to
/// live state would then be showing one set and about to archive another, and the user would
/// have no way to tell.
///
/// So the confirmation is wired to *this* instead: a value copied out of the window at the moment
/// the user asked to review the set, holding everything the confirmation screen needs to describe
/// what it is about to do. Nothing recomputes it, nothing refreshes it, and the session refuses
/// to execute it if the live window no longer agrees with it. **The set the user sees is the set
/// that gets archived, or nothing does.**
///
/// ### Why it carries subjects when the durable transaction does not
///
/// This never touches disk. It lives for as long as one sheet is open, it exists to be *read by
/// the person deciding*, and "Subject, received 14 March" is how a person recognises a message.
/// ``MailMutationTransaction`` — the thing that is written down and survives a relaunch — names
/// messages and describes none of them, and that distinction is deliberate rather than an
/// oversight in one of the two.
nonisolated struct ArchiveSelectionSnapshot: Identifiable, Equatable, Sendable {

    /// The logical mutation this confirmation will become.
    ///
    /// Generated when the snapshot is frozen, carried into ``MailArchiveSelection`` and into the
    /// durable transaction. One confirmation is one identifier, which is what makes a repeated
    /// press recognisably the same operation rather than a second one.
    let id: UUID

    /// The account every message in the set was loaded from.
    let accountAddress: String

    /// The sender every message in the set belongs to.
    ///
    /// A set is always one sender's messages. Carried so the session can re-check it: a
    /// selection that had grown to include another sender's mail would be a selection the user
    /// never made on the screen they made it on.
    let senderKey: SenderSummary.ID

    /// The sender, worded as the review screen displays it.
    let senderDisplayValue: String

    /// Which part of the mailbox was loaded when the set was frozen.
    ///
    /// The loaded window's identity, in the one field that can change what "still loaded" means
    /// without any individual message moving. Switch from Inbox to All mail between reviewing a
    /// set and confirming it and every identifier is still present, still this sender's, and
    /// still findable — but the list the user read was a list of inbox mail and the window under
    /// it is not. Carried so the session can refuse that rather than quietly archive against a
    /// window the user never saw.
    let scope: MailboxScope

    /// The messages, in the order the review screen listed them.
    let messages: [SelectedMessage]

    /// When the set was frozen. Shown nowhere; it is the answer to "how stale is this?".
    let frozenAt: Date

    init(
        id: UUID = UUID(),
        accountAddress: String,
        senderKey: SenderSummary.ID,
        senderDisplayValue: String,
        scope: MailboxScope,
        messages: [SelectedMessage],
        frozenAt: Date
    ) {
        self.id = id
        self.accountAddress = accountAddress
        self.senderKey = senderKey
        self.senderDisplayValue = senderDisplayValue
        self.scope = scope
        self.messages = messages
        self.frozenAt = frozenAt
    }

    /// One message, as the confirmation describes it.
    ///
    /// Metadata only, and only the three fields a person needs to recognise which message this
    /// is. There is no body to carry and nowhere in ``MailMessage`` to have held one.
    nonisolated struct SelectedMessage: Identifiable, Equatable, Sendable {

        let id: MailMessageID
        let subject: String?
        let receivedAt: Date

        /// Why this message is protected, if it is.
        ///
        /// Frozen with the rest: the confirmation warns about the protected messages *as they
        /// were when the user reviewed them*, so the warning on screen always matches the list
        /// on screen.
        let protectionReason: CleanupExclusionReason?

        var isProtected: Bool { protectionReason != nil }
    }

    // MARK: - Derived

    var messageIDs: [MailMessageID] { messages.map(\.id) }

    var count: Int { messages.count }

    /// The protected messages in the set, which the confirmation calls out by name.
    ///
    /// Non-empty only when the user selected them *by hand* — no convenience action puts a
    /// protected message in a selection. See ``InboxSessionModel/preselectableMessageIDs(for:)``.
    var protectedMessages: [SelectedMessage] { messages.filter(\.isProtected) }

    var containsProtectedMessages: Bool { messages.contains(where: \.isProtected) }

    /// The frozen set, as the mutation boundary wants it.
    ///
    /// `nil` for an empty snapshot, which the session never builds — "archive nothing" is not an
    /// operation.
    func selection() -> MailArchiveSelection? {
        MailArchiveSelection(
            messageIDs: messageIDs,
            accountAddress: accountAddress,
            operationID: id
        )
    }
}

import Foundation

/// The one thing InboxSweep can change about a mailbox: whether a single, named message is in
/// the inbox.
///
/// This is a **separate boundary from ``MailMessageFetching`` on purpose.** Reading and writing
/// are not two flavours of the same capability, and folding an archive method into the fetching
/// protocol would have made every reader a writer, including the synthetic mailbox and every
/// future provider. Keeping them apart means a provider that cannot write says so by not
/// vending one of these at all, and the session that holds no archiver has no code path to a
/// mutation rather than a disabled button.
///
/// The surface is as small as archive-and-undo can be made:
///
/// - one message per call, named by its provider identifier: there is no batch form, no
///   sender form, and no "everything matching" form;
/// - inbox membership only: there is no parameter for which label to add or remove, so this
///   cannot express "move to Trash", "mark read", or "apply my own label";
/// - nothing about trashing, deleting, sending, or settings, in any shape.
///
/// `SafetyBoundaryTests` asserts each of those, so widening this protocol is a change someone
/// has to make deliberately and defend.
nonisolated protocol MailMessageArchiving: Sendable {

    /// Whether the authorization in hand covers archiving.
    ///
    /// Asked before the user is offered the action, so a grant that predates the permission
    /// produces an explanation and an offer to re-authorize rather than a failed write.
    func archiveCapability() async -> MailMutationCapability

    /// Asks the user for the archive permission and reports what they granted.
    ///
    /// Interactive: this presents the provider's own consent screen. It must leave the existing
    /// authorization intact when the user declines, and must refuse, without disturbing the
    /// current session, if the account that comes back is not the one already connected.
    func authorizeArchiving() async throws -> MailMutationCapability

    /// Takes exactly one message out of the inbox, leaving it in the mailbox.
    ///
    /// Returns only once the provider has confirmed the change. Implementations must not report
    /// success from a request they have merely sent.
    func archive(_ request: MailArchiveRequest) async throws -> MailArchiveReceipt

    /// Puts exactly one message back into the inbox: the undo of ``archive(_:)``.
    ///
    /// A real request to the provider, not a local correction: an undo that only changed this
    /// Mac's idea of the mailbox would leave the user's mail archived while the app claimed
    /// otherwise.
    func restoreToInbox(_ request: MailArchiveRequest) async throws -> MailArchiveReceipt
}

/// Which of the two operations a mutation is.
///
/// An enum rather than a Boolean so a record reads as what happened rather than as a flag, and
/// so adding a third operation is a visible change here.
nonisolated enum MailMutationOperation: String, Hashable, Sendable, CaseIterable {

    /// Remove the message from the inbox. It stays in the mailbox.
    case archive

    /// Put the message back in the inbox.
    case restoreToInbox

    /// The verb, in the past tense, for a result line.
    var completedVerbPhrase: String {
        switch self {
        case .archive: "archived"
        case .restoreToInbox: "put back in your inbox"
        }
    }

    /// The verb, in the present participle, for a progress line.
    var inProgressVerbPhrase: String {
        switch self {
        case .archive: "Archiving"
        case .restoreToInbox: "Putting back"
        }
    }

    /// The operation that undoes this one.
    var inverse: MailMutationOperation {
        switch self {
        case .archive: .restoreToInbox
        case .restoreToInbox: .archive
        }
    }
}

/// A request to change one message's inbox membership.
///
/// Carries the account it believes it is acting for, because the boundary re-checks that rather
/// than trusting the caller. A request assembled while one account was connected must not be
/// executed against another, and the cheapest way to guarantee that is to make every request
/// say whose mailbox it is for.
nonisolated struct MailArchiveRequest: Hashable, Sendable {

    /// The single message to act on.
    let messageID: MailMessageID

    /// The address of the account the message was loaded from.
    let accountAddress: String

    /// Identifies this *logical* mutation.
    ///
    /// Stable across a retry of the same user action, so a double-click, a repeated callback, or
    /// a transport-level retry all write one record rather than several.
    let operationID: UUID

    init(messageID: MailMessageID, accountAddress: String, operationID: UUID = UUID()) {
        self.messageID = messageID
        self.accountAddress = accountAddress
        self.operationID = operationID
    }
}

/// What the provider confirmed it did.
///
/// Carries the labels the provider reported *after* the change rather than the ones the app
/// assumed it would produce, so local state is reconciled against what the mailbox actually
/// says. That is what makes "InboxSweep thinks this is archived" and "this is archived"
/// the same statement.
nonisolated struct MailArchiveReceipt: Hashable, Sendable {

    /// The message the provider acted on. Checked against the request.
    let messageID: MailMessageID

    /// Which operation the provider confirmed.
    let operation: MailMutationOperation

    /// The labels the message carries now, as the provider reported them.
    let labelsAfterMutation: Set<MailLabel>

    /// Whether the message is in the inbox now, according to the provider.
    var isInInbox: Bool { labelsAfterMutation.contains(.inbox) }

    /// Whether the receipt agrees with the operation that was asked for.
    ///
    /// A provider that returned success while leaving the message in the inbox has not done
    /// what was asked, and the app would rather say so than quietly show the wrong state.
    var confirmsOperation: Bool {
        switch operation {
        case .archive: !isInInbox
        case .restoreToInbox: isInInbox
        }
    }
}

/// Whether archiving is available, and if not, why not.
nonisolated enum MailMutationCapability: Equatable, Sendable {

    /// This provider cannot change a mailbox at all: the synthetic mailbox, for one.
    ///
    /// Not a permission problem and not fixable by re-authorizing, so the UI offers nothing
    /// rather than offering a reconnect that would change nothing.
    case unsupported

    /// The authorization in hand covers archiving.
    case granted

    /// The provider could archive, but the grant in hand does not cover it, including when
    /// there is no grant at all. Asking the user for the extra permission is the way forward.
    case requiresAdditionalPermission

    var isGranted: Bool { self == .granted }

    /// Whether offering the user a re-authorization would actually help.
    var isUpgradable: Bool { self == .requiresAdditionalPermission }
}

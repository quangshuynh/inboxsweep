import Foundation

/// Establishes and tears down the app's authorization to read a mail account.
///
/// Deliberately narrow: connect, disconnect, and ask what the current state is. There is no
/// method here to hand out a token, because nothing above this boundary should ever hold one.
nonisolated protocol MailAccountAuthorizing: Sendable {

    /// The current connection, without performing any user-visible sign-in.
    func currentConnection() async -> MailConnection

    /// Re-establishes a connection from previously stored credentials, if any.
    ///
    /// Non-throwing, because every way this can end is a case of ``MailRestoreOutcome`` —
    /// including the failures. An implementation that threw would push callers back towards
    /// `try?`, which is precisely how a Keychain refusal came to be reported as "no account".
    func restoreConnection() async -> MailRestoreOutcome

    /// Starts an interactive sign-in and returns the connected account.
    func connect() async throws -> MailAccount

    /// Whether the last successful sign-in was persisted for the next launch.
    ///
    /// Asked *after* connecting. A provider that cannot persist still returns a usable account
    /// — the session works — so this is a warning the UI can show, never a failure.
    func storedAuthorizationState() async -> StoredAuthorizationState

    /// Discards stored credentials and returns to a signed-out state.
    ///
    /// Non-throwing: signing out must always succeed from the user's point of view, even if
    /// revoking remotely fails. Not *silent*, though — the returned
    /// ``MailDisconnectOutcome`` says whether the stored credential was really removed, because
    /// "we told you that you were signed out and left the refresh token where it was" is not a
    /// thing this app should be able to do without saying so.
    func disconnect() async -> MailDisconnectOutcome
}

/// Reads bounded windows of message metadata.
///
/// Still has no method that writes anything, and still will not gain one. Since this interval
/// the app *can* change one thing about a mailbox — whether a single named message is in the
/// inbox — and that lives behind ``MailMessageArchiving``, a separate protocol a provider
/// vends only if it can perform it. Keeping the two apart is what lets a reader be a reader:
/// nothing that holds only this protocol has a path to a mutation, and `SafetyBoundaryTests`
/// asserts that no method here is named after one.
nonisolated protocol MailMessageFetching: Sendable {

    /// Fetches one page of message metadata.
    ///
    /// Implementations must honour cancellation and must not fetch message bodies.
    func fetchMessages(_ request: MailFetchRequest) async throws -> MailMessagePage
}

/// A mail account InboxSweep can connect to and read metadata from.
///
/// Reading is required of every provider. Writing is not: ``messageArchiver`` is optional, and
/// a provider that returns `nil` cannot be asked to change anything because there is no object
/// to ask. That is how the synthetic mailbox stays synthetic without anybody having to
/// remember to guard it.
nonisolated protocol MailProvider: MailAccountAuthorizing, MailMessageFetching {

    /// A short name for the provider, for display only.
    var displayName: String { get }

    /// The narrow mutation boundary, when this provider has one.
    ///
    /// Vended *by the provider* rather than supplied alongside it, so the object that performs
    /// a mutation is always the one holding the authorization the messages were read with.
    /// There is no way to pair one account's archiver with another account's window, because
    /// there is no way to hand them to the session separately.
    var messageArchiver: (any MailMessageArchiving)? { get }
}

nonisolated extension MailProvider {

    /// Providers cannot write unless they say otherwise.
    ///
    /// The default is the safe one on purpose: a new provider is read-only until somebody
    /// deliberately implements a mutation boundary for it.
    var messageArchiver: (any MailMessageArchiving)? { nil }
}

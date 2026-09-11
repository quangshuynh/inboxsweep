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
    /// Best-effort and non-throwing: signing out must always succeed from the user's point of
    /// view, even if revoking remotely fails.
    func disconnect() async
}

/// Reads bounded windows of message metadata.
///
/// There is no counterpart to this protocol for *writing*. The app exposes no operation to
/// delete, archive, label, mark, move, or send mail, and the absence is structural: no such
/// method exists to call. The cleanup planner names such actions in order to describe them and
/// reaches this boundary not at all. See `SafetyBoundaryTests` for the assertions that keep it
/// that way.
nonisolated protocol MailMessageFetching: Sendable {

    /// Fetches one page of message metadata.
    ///
    /// Implementations must honour cancellation and must not fetch message bodies.
    func fetchMessages(_ request: MailFetchRequest) async throws -> MailMessagePage
}

/// A mail account InboxSweep can connect to and read metadata from.
nonisolated protocol MailProvider: MailAccountAuthorizing, MailMessageFetching {

    /// A short name for the provider, for display only.
    var displayName: String { get }
}

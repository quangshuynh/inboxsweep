import Foundation

/// The account InboxSweep is currently connected to.
nonisolated struct MailAccount: Hashable, Sendable {
    /// The signed-in user's own address.
    let emailAddress: EmailAddress

    /// A short name for the provider, for display only (e.g. "Gmail").
    let providerDisplayName: String

    /// Total messages the provider reports in the mailbox, when it offers a cheap count.
    ///
    /// Used only to tell the user how much of their mailbox the loaded window covers.
    let providerMessageCount: Int?

    init(emailAddress: EmailAddress, providerDisplayName: String, providerMessageCount: Int? = nil) {
        self.emailAddress = emailAddress
        self.providerDisplayName = providerDisplayName
        self.providerMessageCount = providerMessageCount
    }
}

/// Whether the app currently holds a usable authorization for a mail account.
nonisolated enum MailConnection: Hashable, Sendable {
    case disconnected
    case connected(MailAccount)

    var account: MailAccount? {
        if case .connected(let account) = self { return account }
        return nil
    }

    var isConnected: Bool { account != nil }
}

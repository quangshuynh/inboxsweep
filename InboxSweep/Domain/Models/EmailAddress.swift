import Foundation

/// An app-owned representation of a mail sender.
///
/// `EmailAddress` is deliberately provider-neutral: nothing in this type knows that the
/// message it came from was fetched from Gmail. Values are always *normalized* (see
/// ``EmailAddressParser``) so that the same human sender produces the same value — and the
/// same ``groupingKey`` — no matter how the raw header was formatted.
nonisolated struct EmailAddress: Hashable, Sendable, Codable {

    /// The sender's display name, if the header carried a usable one.
    ///
    /// Trimmed, unquoted, and never an empty string (absent names are `nil`).
    let displayName: String?

    /// The normalized address, e.g. `newsletter@example.com`.
    ///
    /// Empty when the source header carried no parseable address. Normalization is
    /// lowercasing plus whitespace trimming only — see ``EmailAddressParser`` for the
    /// full set of rules and for why sub-addressing is deliberately preserved.
    let address: String

    init(displayName: String?, address: String) {
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = (trimmedName?.isEmpty == false) ? trimmedName : nil
        self.address = address
    }

    /// A sender whose address could not be determined.
    static let unknown = EmailAddress(displayName: nil, address: "")

    /// Whether a usable address was recovered from the source header.
    var hasAddress: Bool { !address.isEmpty }

    /// The value used to group messages by sender.
    ///
    /// All senders without a parseable address share the single ``unknownGroupingKey``
    /// bucket. That is a deliberate trade: it keeps grouping deterministic and prevents a
    /// stream of malformed headers from fragmenting the dashboard into noise.
    var groupingKey: String { hasAddress ? address : Self.unknownGroupingKey }

    static let unknownGroupingKey = "<unknown-sender>"

    /// A value that is always safe to put in front of a person.
    ///
    /// Prefers the display name, falls back to the address, and finally to a neutral
    /// placeholder. Never returns an empty string.
    var displayValue: String {
        if let displayName { return displayName }
        if hasAddress { return address }
        return "Unknown sender"
    }

    /// A secondary line for the UI: the address, but only when it adds information.
    var secondaryDisplayValue: String? {
        guard hasAddress, displayName != nil else { return nil }
        return address
    }
}

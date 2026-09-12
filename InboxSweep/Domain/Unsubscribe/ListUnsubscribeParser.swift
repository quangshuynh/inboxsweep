import Foundation

/// Parses `List-Unsubscribe` and `List-Unsubscribe-Post` into typed values.
///
/// ### What the headers actually look like
///
/// RFC 2369 defines `List-Unsubscribe` as a comma-separated list of URLs, each in angle
/// brackets:
///
/// ```
/// List-Unsubscribe: <mailto:unsub@lists.example>, <https://lists.example/u/abc>
/// ```
///
/// RFC 8058 adds a second header that marks the HTTPS entry as a one-click endpoint:
///
/// ```
/// List-Unsubscribe-Post: List-Unsubscribe=One-Click
/// ```
///
/// Real mail deviates from both in every direction: missing brackets, stray whitespace,
/// duplicate values, a `List-Unsubscribe-Post` with no HTTPS URL to go with it, schemes that
/// have no business in a mail header at all.
///
/// ### The posture
///
/// Total, ordered, and unforgiving about brackets.
///
/// - **Total.** Every value produces a ``UnsubscribeTarget``, including the ones being refused.
///   Nothing is dropped silently, because "the sender sent something InboxSweep will not use"
///   is worth saying on screen.
/// - **Ordered.** Values come back in header order, which is what the mechanism-selection rules
///   break ties on. See ``UnsubscribeMechanismSelection``.
/// - **Brackets are required.** An unbracketed value is recorded as
///   ``UnsupportedUnsubscribeValue/Reason/notBracketed`` even when it would have parsed as a
///   perfectly good URL. This is the one place the parser is stricter than it has to be, and
///   deliberately so: the bracket is the only thing separating "a URL the sender declared" from
///   "some text that happens to be in this header", and the consequence of guessing is a
///   request to a third party.
///
/// Nothing here fetches, opens, resolves, or normalizes a destination. It reads text and
/// returns values.
nonisolated enum ListUnsubscribeParser {

    /// The exact `List-Unsubscribe-Post` value RFC 8058 defines.
    static let oneClickPostValue = "List-Unsubscribe=One-Click"

    /// How many values are read from one header.
    ///
    /// A header with more entries than this is not one a mailing list wrote, and the parse is
    /// bounded rather than trusting a header's length. The extras are dropped and the result is
    /// still usable: the first values are the ones selection would have chosen anyway.
    static let maximumValues = 10

    // MARK: - List-Unsubscribe

    /// Parses one `List-Unsubscribe` header value into targets, in header order.
    ///
    /// Duplicates (the same destination listed twice, which happens when a sender's mail
    /// system appends its own copy) are collapsed, keeping the first occurrence, so a header
    /// cannot make the review sheet list one destination twice.
    static func targets(in header: String) -> [UnsubscribeTarget] {
        var seen = Set<UnsubscribeTarget>()
        return split(header)
            .prefix(maximumValues)
            .map(target(forValue:))
            .filter { seen.insert($0).inserted }
    }

    /// Splits on commas that are outside angle brackets.
    ///
    /// A plain `split(separator: ",")` is wrong here: a URL may legitimately contain a comma in
    /// its query, and cutting there produces two malformed halves out of one good value.
    static func split(_ header: String) -> [String] {
        var values: [String] = []
        var current = ""
        var depth = 0

        for character in header {
            switch character {
            case "<":
                depth += 1
                current.append(character)
            case ">":
                depth = max(0, depth - 1)
                current.append(character)
            case "," where depth == 0:
                values.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        values.append(current)

        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Classifies one already-split value.
    static func target(forValue raw: String) -> UnsubscribeTarget {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count > 2 else {
            return .unsupported(UnsupportedUnsubscribeValue(reason: .notBracketed, scheme: scheme(of: trimmed)))
        }

        // Whitespace inside the brackets is common and harmless: folded headers arrive with
        // newlines in them, so it is removed rather than treated as a malformation.
        let inner = trimmed
            .dropFirst()
            .dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !inner.isEmpty else {
            return .unsupported(UnsupportedUnsubscribeValue(reason: .malformed))
        }

        let scheme = scheme(of: inner)

        switch scheme {
        case "https":
            if let url = HTTPSUnsubscribeURL(string: inner) { return .web(url) }
            // The scheme was right, so the failure is the rest of it: no host, or not a URL.
            return .unsupported(
                UnsupportedUnsubscribeValue(
                    reason: URL(string: inner) == nil ? .malformed : .missingHost,
                    scheme: scheme
                )
            )

        case "mailto":
            if let address = MailtoUnsubscribeAddress(string: inner) { return .mail(address) }
            return .unsupported(UnsupportedUnsubscribeValue(reason: .unusableMailAddress, scheme: scheme))

        case "http":
            return .unsupported(UnsupportedUnsubscribeValue(reason: .insecureScheme, scheme: scheme))

        case .some(let scheme):
            return .unsupported(UnsupportedUnsubscribeValue(reason: .disallowedScheme, scheme: scheme))

        case nil:
            return .unsupported(UnsupportedUnsubscribeValue(reason: .malformed))
        }
    }

    /// The scheme of a value, lowercased, without building a `URL` for it.
    ///
    /// Read off the text rather than from `URL.scheme` on purpose: `URL(string:)` rejects some
    /// malformed values outright, and the scheme is precisely what the refusal needs to name
    /// when it does.
    static func scheme(of value: String) -> String? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let candidate = value[value.startIndex..<colon]
        guard !candidate.isEmpty,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
              candidate.first?.isLetter == true
        else { return nil }
        return candidate.lowercased()
    }

    // MARK: - List-Unsubscribe-Post

    /// Whether a `List-Unsubscribe-Post` header declares RFC 8058 one-click semantics.
    ///
    /// Matched case-insensitively with surrounding whitespace removed, because senders vary the
    /// casing and folding of a header whose value the RFC spells one particular way. Nothing
    /// looser than that: a header saying anything other than `List-Unsubscribe=One-Click` is
    /// **not** a one-click declaration, and the app will not infer one from a URL that happens
    /// to look like an API endpoint.
    static func declaresOneClick(post header: String?) -> Bool {
        guard let header else { return false }
        let normalized = header
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
        return normalized.caseInsensitiveCompare(
            oneClickPostValue.replacingOccurrences(of: " ", with: "")
        ) == .orderedSame
    }

    // MARK: - Whole-message metadata

    /// Parses both headers together into the value a message carries.
    ///
    /// `listUnsubscribe` being `nil` means the message had no such header at all, which is a
    /// different state from a header that parsed to nothing; see
    /// ``MessageUnsubscribeMetadata``.
    static func metadata(
        listUnsubscribe: String?,
        listUnsubscribePost: String?
    ) -> MessageUnsubscribeMetadata {
        guard let listUnsubscribe else {
            // A `List-Unsubscribe-Post` with no `List-Unsubscribe` beside it is meaningless:
            // there is nothing for it to declare one-click semantics *about*. It is recorded as
            // nothing rather than as a mechanism.
            return .absent
        }
        return MessageUnsubscribeMetadata(
            targets: targets(in: listUnsubscribe),
            declaresOneClickPost: declaresOneClick(post: listUnsubscribePost),
            headerWasPresent: true
        )
    }
}

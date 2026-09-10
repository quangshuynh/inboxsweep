import Foundation

/// Turns a raw RFC 5322 `From` header into a normalized ``EmailAddress``.
///
/// Normalization is deterministic and total: every input, including `nil`, garbage, and
/// headers with no address at all, produces a value. Nothing here can throw or trap, because
/// a single malformed header in a real mailbox must never take the app down.
///
/// ### Normalization rules
/// 1. RFC 2047 encoded-words are decoded first, so `=?UTF-8?B?...?=` becomes readable text.
/// 2. The address is taken from the first `<angle-addr>` if one is present; otherwise from the
///    last whitespace-separated token that looks like an address.
/// 3. Addresses are lowercased in full and stripped of surrounding whitespace and punctuation.
/// 4. Display names are unquoted, unescaped, and trimmed; an empty result becomes `nil`.
/// 5. Sub-addressing (`user+tag@`) and dots in the local part are **preserved**. Gmail treats
///    those as the same account, but other providers do not, and collapsing them would merge
///    senders the user considers distinct.
nonisolated enum EmailAddressParser {

    /// Parses a `From` header value. Returns ``EmailAddress/unknown`` when nothing usable is present.
    static func parse(_ headerValue: String?) -> EmailAddress {
        guard let headerValue else { return .unknown }

        let decoded = MIMEEncodedWordDecoder.decode(headerValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return .unknown }

        // `Display Name <addr@example.com>` — the common, well-formed shape.
        if let angleStart = decoded.firstIndex(of: "<"),
           let angleEnd = decoded[angleStart...].firstIndex(of: ">") {
            return EmailAddress(
                displayName: normalizeDisplayName(decoded[decoded.startIndex..<angleStart]),
                address: normalizeAddress(decoded[decoded.index(after: angleStart)..<angleEnd]) ?? ""
            )
        }

        // A bare `addr@example.com`, optionally with an unquoted phrase before it or an RFC
        // 5322 comment after it. Both turn up often enough in real mail to be worth reading.
        let tokens = decoded.split(whereSeparator: \.isWhitespace)
        if let addressIndex = tokens.lastIndex(where: { $0.contains("@") }),
           let address = normalizeAddress(tokens[addressIndex]) {
            var phraseTokens = tokens
            phraseTokens.remove(at: addressIndex)
            let phrase = phraseTokens.joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            return EmailAddress(displayName: normalizeDisplayName(Substring(phrase)), address: address)
        }

        // Words but no parseable address: keep the words for display. The value still groups
        // into the shared "unknown sender" bucket.
        return EmailAddress(displayName: normalizeDisplayName(Substring(decoded)), address: "")
    }

    /// Normalizes a single candidate token, returning `nil` if it is not a usable `addr-spec`.
    private static func normalizeAddress(_ candidate: Substring) -> String? {
        var text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        // `mailto:` prefixes turn up in exported and rewritten headers.
        if text.lowercased().hasPrefix("mailto:") {
            text = String(text.dropFirst("mailto:".count))
        }

        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "<>,;\"'"))
        guard !cleaned.isEmpty, cleaned.allSatisfy({ !$0.isWhitespace }) else { return nil }

        let parts = cleaned.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              !parts[1].hasPrefix("."),
              !parts[1].hasSuffix(".")
        else { return nil }

        return cleaned.lowercased()
    }

    /// Unquotes, unescapes, and trims a display-name phrase.
    private static func normalizeDisplayName(_ candidate: Substring) -> String? {
        var text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

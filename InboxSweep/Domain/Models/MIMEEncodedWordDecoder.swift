import Foundation

/// Decodes RFC 2047 "encoded-word" sequences that appear in mail headers.
///
/// Real inbox headers routinely look like `=?UTF-8?B?Q2Fmw6k=?=`. Without decoding, sender
/// names and subjects show up in the UI as unreadable machine text, so this runs on every
/// header value we surface to a person.
///
/// The decoder is fail-soft by design: any token it cannot decode is passed through
/// verbatim rather than dropped, so a malformed header degrades to ugly text instead of an
/// empty or missing value.
nonisolated enum MIMEEncodedWordDecoder {

    /// Returns `value` with every well-formed encoded-word replaced by its decoded text.
    ///
    /// Per RFC 2047 §6.2, whitespace *between* two adjacent encoded-words is removed, while
    /// whitespace between an encoded-word and ordinary text is preserved.
    static func decode(_ value: String) -> String {
        guard value.contains("=?") else { return value }

        var segments: [Segment] = []
        var remainder = Substring(value)
        var undecodable = ""

        while let start = remainder.range(of: "=?") {
            let literal = remainder[remainder.startIndex..<start.lowerBound]
            let afterStart = remainder[start.upperBound...]

            guard let end = afterStart.range(of: "?="),
                  let decoded = decodeToken(afterStart[afterStart.startIndex..<end.lowerBound])
            else {
                // Not a valid encoded-word. Keep the `=?` as literal text and scan onward.
                undecodable += literal + "=?"
                remainder = afterStart
                continue
            }

            segments.append(.literal(undecodable + literal))
            segments.append(.encoded(decoded))
            undecodable = ""
            remainder = afterStart[end.upperBound...]
        }

        segments.append(.literal(undecodable + remainder))
        return join(segments)
    }

    private enum Segment {
        case literal(String)
        case encoded(String)

        var isEncoded: Bool { if case .encoded = self { return true } else { return false } }
    }

    private static func join(_ segments: [Segment]) -> String {
        var output = ""
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .encoded(let text):
                output += text
            case .literal(let text):
                guard !text.isEmpty else { continue }
                let isBetweenEncodedWords = index > 0
                    && index + 1 < segments.count
                    && segments[index - 1].isEncoded
                    && segments[index + 1].isEncoded
                if isBetweenEncodedWords && text.allSatisfy(\.isWhitespace) { continue }
                output += text
            }
        }
        return output
    }

    /// Decodes the interior of an encoded-word: `charset?encoding?text`.
    private static func decodeToken(_ token: Substring) -> String? {
        let parts = token.split(separator: "?", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        // A language suffix (`utf-8*en`) is legal per RFC 2231 and carries no display meaning.
        let charsetName = String(parts[0].split(separator: "*", maxSplits: 1)[0])
        guard let encoding = stringEncoding(forIANACharset: charsetName) else { return nil }

        let text = parts[2]
        switch parts[1].lowercased() {
        case "b": return decodeBase64(text, using: encoding)
        case "q": return decodeQuotedPrintable(text, using: encoding)
        default: return nil
        }
    }

    private static func stringEncoding(forIANACharset name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private static func decodeBase64(_ text: Substring, using encoding: String.Encoding) -> String? {
        // Some senders omit base64 padding; restore it before decoding.
        var padded = String(text)
        if padded.count % 4 != 0 {
            padded += String(repeating: "=", count: 4 - (padded.count % 4))
        }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: encoding)
    }

    private static func decodeQuotedPrintable(_ text: Substring, using encoding: String.Encoding) -> String? {
        var bytes: [UInt8] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character == "_" {
                bytes.append(0x20)
                index = text.index(after: index)
            } else if character == "=" {
                let hexStart = text.index(after: index)
                guard let hexEnd = text.index(hexStart, offsetBy: 2, limitedBy: text.endIndex),
                      let byte = UInt8(text[hexStart..<hexEnd], radix: 16)
                else { return nil }
                bytes.append(byte)
                index = hexEnd
            } else {
                guard let scalar = character.asciiValue else { return nil }
                bytes.append(scalar)
                index = text.index(after: index)
            }
        }

        return String(data: Data(bytes), encoding: encoding)
    }
}

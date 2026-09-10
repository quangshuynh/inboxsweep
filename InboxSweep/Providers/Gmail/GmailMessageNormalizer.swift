import Foundation

/// Converts Gmail's wire format into app-owned domain models.
///
/// This is the only place Gmail's vocabulary is translated, and it is total: any message
/// Gmail returns produces a ``MailMessage``, however incomplete or malformed. Dropping
/// messages would silently understate a sender's volume, and throwing would let one bad
/// header take down a whole load, so the normalizer degrades instead.
nonisolated enum GmailMessageNormalizer {

    /// Gmail's system label IDs, mapped onto the app's provider-neutral vocabulary.
    private static let labelMapping: [String: MailLabel] = [
        "INBOX": .inbox,
        "UNREAD": .unread,
        "STARRED": .starred,
        "IMPORTANT": .important,
        "SENT": .sent,
        "DRAFT": .draft,
        "SPAM": .spam,
        "TRASH": .trash,
        "CATEGORY_PROMOTIONS": .categoryPromotions,
        "CATEGORY_SOCIAL": .categorySocial,
        "CATEGORY_UPDATES": .categoryUpdates,
        "CATEGORY_FORUMS": .categoryForums,
        "CATEGORY_PERSONAL": .categoryPersonal,
    ]

    static func normalize(_ dto: GmailDTO.Message) -> MailMessage {
        let headers = HeaderLookup(dto.payload?.headers ?? [])

        return MailMessage(
            id: MailMessageID(dto.id),
            threadID: dto.threadId.map { MailThreadID($0) },
            sender: EmailAddressParser.parse(headers["From"]),
            subject: normalizeSubject(headers["Subject"]),
            receivedAt: receivedDate(internalDate: dto.internalDate, dateHeader: headers["Date"]),
            labels: labels(from: dto.labelIds ?? []),
            hasListUnsubscribeHeader: headers["List-Unsubscribe"] != nil
        )
    }

    static func normalize(_ dtos: [GmailDTO.Message]) -> [MailMessage] {
        dtos.map(normalize)
    }

    // MARK: - Fields

    static func labels(from identifiers: [String]) -> Set<MailLabel> {
        Set(identifiers.map { labelMapping[$0] ?? .other($0) })
    }

    private static func normalizeSubject(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let decoded = MIMEEncodedWordDecoder.decode(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    /// Prefers Gmail's `internalDate` over the `Date` header.
    ///
    /// `internalDate` is when Gmail received the message; the `Date` header is written by the
    /// sender and is routinely wrong or fabricated. Falling back to it is better than nothing,
    /// and `.distantPast` is the last resort so a dateless message still appears rather than
    /// being dropped or defaulting to "now" and looking like the newest mail in the mailbox.
    static func receivedDate(internalDate: String?, dateHeader: String?) -> Date {
        if let internalDate, let milliseconds = Double(internalDate), milliseconds > 0 {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        if let dateHeader, let parsed = rfc5322Formatter.date(from: dateHeader) {
            return parsed
        }
        return .distantPast
    }

    private static let rfc5322Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    /// Case-insensitive header lookup, because header names are not case-sensitive and Gmail
    /// echoes whatever casing the sender used.
    private struct HeaderLookup {
        private let values: [String: String]

        init(_ headers: [GmailDTO.Header]) {
            var values: [String: String] = [:]
            for header in headers {
                guard let value = header.value else { continue }
                // First occurrence wins, matching how mail clients treat duplicated headers.
                values[header.name.lowercased()] = values[header.name.lowercased()] ?? value
            }
            self.values = values
        }

        subscript(name: String) -> String? {
            values[name.lowercased()]
        }
    }
}

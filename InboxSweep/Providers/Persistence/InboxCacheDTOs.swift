import Foundation

/// The on-disk shape of a cached window, and the mapping to and from domain models.
///
/// Kept separate from the domain types for the same reason ``GmailDTO`` is: the file format is
/// an adapter concern. Domain models stay free to be renamed or reshaped, and when they are,
/// the break shows up here as a compile error rather than silently as a file the next build
/// misreads.
///
/// Every key is written out explicitly. A synthesized `Codable` would tie the format to Swift
/// property names, so renaming a field would quietly invalidate everybody's cache.
nonisolated enum InboxCacheDTO {

    /// Bumped whenever the shape below changes incompatibly. A file written by any other
    /// version is discarded and refetched rather than guessed at.
    static let schemaVersion = 1

    /// How dates are written: seconds since the epoch, as a number.
    ///
    /// Chosen over ISO 8601 because it round-trips exactly, including the sub-second precision
    /// Gmail's millisecond timestamps carry.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    // MARK: - Wire types

    struct Record: Codable, Equatable {
        var version: Int
        var accountAddress: String
        var accountDisplayName: String?
        var providerDisplayName: String
        var providerMessageCount: Int?
        var nextPageToken: String?
        var savedAt: Date
        var messages: [Message]
        var senders: [Sender]

        enum CodingKeys: String, CodingKey {
            case version = "v"
            case accountAddress = "account"
            case accountDisplayName = "account_name"
            case providerDisplayName = "provider"
            case providerMessageCount = "provider_message_count"
            case nextPageToken = "next_page_token"
            case savedAt = "saved_at"
            case messages
            case senders
        }
    }

    struct Message: Codable, Equatable {
        var id: String
        var threadID: String?
        var senderDisplayName: String?
        var senderAddress: String
        var subject: String?
        var receivedAt: Date
        var labels: [String]
        var hasListUnsubscribeHeader: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case threadID = "thread_id"
            case senderDisplayName = "from_name"
            case senderAddress = "from"
            case subject
            case receivedAt = "received_at"
            case labels
            case hasListUnsubscribeHeader = "list_unsubscribe"
        }
    }

    struct Sender: Codable, Equatable {
        var displayName: String?
        var address: String
        var messageCount: Int
        var unreadCount: Int
        var starredCount: Int
        var importantCount: Int
        var newestReceivedAt: Date
        var oldestLoadedReceivedAt: Date
        var recentSubjects: [String]
        var categoryLabels: [String]
        var listUnsubscribeCount: Int
        var averageIntervalBetweenLoadedMessages: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case displayName = "name"
            case address
            case messageCount = "messages"
            case unreadCount = "unread"
            case starredCount = "starred"
            case importantCount = "important"
            case newestReceivedAt = "newest_at"
            case oldestLoadedReceivedAt = "oldest_at"
            case recentSubjects = "recent_subjects"
            case categoryLabels = "categories"
            case listUnsubscribeCount = "list_unsubscribe_count"
            case averageIntervalBetweenLoadedMessages = "average_interval"
        }
    }

    // MARK: - Domain → wire

    static func record(from inbox: CachedInbox) -> Record {
        Record(
            version: schemaVersion,
            accountAddress: inbox.account.emailAddress.address,
            accountDisplayName: inbox.account.emailAddress.displayName,
            providerDisplayName: inbox.account.providerDisplayName,
            providerMessageCount: inbox.account.providerMessageCount,
            nextPageToken: inbox.nextPageToken?.rawValue,
            savedAt: inbox.savedAt,
            messages: inbox.messages.map(message(from:)),
            senders: inbox.senders.map(sender(from:))
        )
    }

    private static func message(from message: MailMessage) -> Message {
        Message(
            id: message.id.rawValue,
            threadID: message.threadID?.rawValue,
            senderDisplayName: message.sender.displayName,
            senderAddress: message.sender.address,
            subject: message.subject,
            receivedAt: message.receivedAt,
            labels: message.labels.map(MailLabelToken.string(for:)).sorted(),
            hasListUnsubscribeHeader: message.hasListUnsubscribeHeader
        )
    }

    private static func sender(from summary: SenderSummary) -> Sender {
        Sender(
            displayName: summary.sender.displayName,
            address: summary.sender.address,
            messageCount: summary.messageCount,
            unreadCount: summary.unreadCount,
            starredCount: summary.starredCount,
            importantCount: summary.importantCount,
            newestReceivedAt: summary.newestReceivedAt,
            oldestLoadedReceivedAt: summary.oldestLoadedReceivedAt,
            recentSubjects: summary.recentSubjects,
            categoryLabels: summary.categoryLabels.map(MailLabelToken.string(for:)).sorted(),
            listUnsubscribeCount: summary.listUnsubscribeCount,
            averageIntervalBetweenLoadedMessages: summary.averageIntervalBetweenLoadedMessages
        )
    }

    // MARK: - Wire → domain

    /// Rebuilds a window from a decoded record, or returns `nil` when the record is not one
    /// this build can use.
    static func inbox(from record: Record) -> CachedInbox? {
        guard record.version == schemaVersion else { return nil }

        return CachedInbox(
            account: MailAccount(
                emailAddress: EmailAddress(
                    displayName: record.accountDisplayName,
                    address: record.accountAddress
                ),
                providerDisplayName: record.providerDisplayName,
                providerMessageCount: record.providerMessageCount
            ),
            messages: record.messages.map(message(from:)),
            senders: record.senders.map(sender(from:)),
            nextPageToken: record.nextPageToken.flatMap { $0.isEmpty ? nil : MailPageToken($0) },
            savedAt: record.savedAt
        )
    }

    private static func message(from dto: Message) -> MailMessage {
        MailMessage(
            id: MailMessageID(dto.id),
            threadID: dto.threadID.map { MailThreadID($0) },
            sender: EmailAddress(displayName: dto.senderDisplayName, address: dto.senderAddress),
            subject: dto.subject,
            receivedAt: dto.receivedAt,
            labels: Set(dto.labels.map(MailLabelToken.label(for:))),
            hasListUnsubscribeHeader: dto.hasListUnsubscribeHeader
        )
    }

    private static func sender(from dto: Sender) -> SenderSummary {
        SenderSummary(
            sender: EmailAddress(displayName: dto.displayName, address: dto.address),
            messageCount: dto.messageCount,
            unreadCount: dto.unreadCount,
            starredCount: dto.starredCount,
            importantCount: dto.importantCount,
            newestReceivedAt: dto.newestReceivedAt,
            oldestLoadedReceivedAt: dto.oldestLoadedReceivedAt,
            recentSubjects: dto.recentSubjects,
            categoryLabels: Set(dto.categoryLabels.map(MailLabelToken.label(for:))),
            listUnsubscribeCount: dto.listUnsubscribeCount,
            averageIntervalBetweenLoadedMessages: dto.averageIntervalBetweenLoadedMessages
        )
    }
}

/// The stable string written for each ``MailLabel``.
///
/// App-owned rather than borrowed from Gmail: the domain's label vocabulary is
/// provider-neutral, and writing Gmail's identifiers into the file would tie every future
/// provider's cache to Gmail's naming. Labels the app does not model keep their provider-side
/// identifier behind an `other:` prefix, so nothing is lost in a round trip.
nonisolated enum MailLabelToken {

    private static let prefixForUnmodelled = "other:"

    private static let names: [MailLabel: String] = [
        .inbox: "inbox",
        .unread: "unread",
        .starred: "starred",
        .important: "important",
        .sent: "sent",
        .draft: "draft",
        .spam: "spam",
        .trash: "trash",
        .categoryPromotions: "category.promotions",
        .categorySocial: "category.social",
        .categoryUpdates: "category.updates",
        .categoryForums: "category.forums",
        .categoryPersonal: "category.personal",
    ]

    private static let labels: [String: MailLabel] = Dictionary(
        uniqueKeysWithValues: names.map { ($0.value, $0.key) }
    )

    static func string(for label: MailLabel) -> String {
        if case .other(let identifier) = label { return prefixForUnmodelled + identifier }
        // Every modelled case is in `names`; the fallback keeps this total if one is added
        // without a token, at the cost of that label decoding as an unmodelled one.
        return names[label] ?? prefixForUnmodelled + label.displayName
    }

    static func label(for token: String) -> MailLabel {
        if token.hasPrefix(prefixForUnmodelled) {
            return .other(String(token.dropFirst(prefixForUnmodelled.count)))
        }
        return labels[token] ?? .other(token)
    }
}

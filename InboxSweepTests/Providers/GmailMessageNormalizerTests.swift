import Foundation
import Testing
@testable import InboxSweep

@Suite("Gmail message normalization")
struct GmailMessageNormalizerTests {

    @Test("A well-formed message becomes a complete domain model")
    func normalizesCompleteMessage() throws {
        let dto = try GmailFixtures.decodeMessage(
            GmailFixtures.SyntheticMessage(
                id: "m-1",
                threadID: "t-1",
                from: "\"The Daily Digest\" <Newsletter@Example.com>",
                subject: "Issue 141",
                internalDateMilliseconds: 1_700_000_000_000,
                labels: ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"],
                listUnsubscribe: "<https://example.com/unsubscribe>"
            )
        )

        let message = GmailMessageNormalizer.normalize(dto)

        #expect(message.id == MailMessageID("m-1"))
        #expect(message.threadID == MailThreadID("t-1"))
        #expect(message.sender.displayName == "The Daily Digest")
        #expect(message.sender.address == "newsletter@example.com")
        #expect(message.subject == "Issue 141")
        #expect(message.receivedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(message.labels == [.inbox, .unread, .categoryPromotions])
        #expect(message.isUnread)
        #expect(!message.isStarred)
        #expect(message.hasListUnsubscribeHeader)
    }

    @Test("Read state, starring, and importance are derived from labels")
    func derivesFlagsFromLabels() throws {
        let dto = try GmailFixtures.decodeMessage(
            GmailFixtures.SyntheticMessage(id: "m-2", labels: ["INBOX", "STARRED", "IMPORTANT"])
        )
        let message = GmailMessageNormalizer.normalize(dto)

        #expect(!message.isUnread)
        #expect(message.isStarred)
        #expect(message.isImportant)
    }

    @Test("Unrecognised labels are carried through rather than discarded")
    func preservesUnknownLabels() {
        let labels = GmailMessageNormalizer.labels(from: ["INBOX", "Label_8837291", "CATEGORY_SOCIAL"])

        #expect(labels.contains(.inbox))
        #expect(labels.contains(.categorySocial))
        #expect(labels.contains(.other("Label_8837291")))
        #expect(labels.first { !$0.isRecognized }?.displayName == "Label_8837291")
    }

    @Test("A missing or unparseable From header produces an unknown sender, not a failure", arguments: [
        nil,
        "",
        "(no sender)",
        "<>",
    ] as [String?])
    func toleratesBrokenSenders(from: String?) throws {
        let dto = try GmailFixtures.decodeMessage(
            GmailFixtures.SyntheticMessage(id: "m-broken", from: from)
        )
        let message = GmailMessageNormalizer.normalize(dto)

        #expect(!message.sender.hasAddress)
        #expect(message.sender.groupingKey == EmailAddress.unknownGroupingKey)
    }

    @Test("A message with no payload at all still normalizes")
    func toleratesMissingPayload() throws {
        let dto = try GmailFixtures.decodeMessage(
            GmailFixtures.SyntheticMessage(id: "m-bare", rawJSON: #"{ "id": "m-bare" }"#)
        )
        let message = GmailMessageNormalizer.normalize(dto)

        #expect(message.id == MailMessageID("m-bare"))
        #expect(message.threadID == nil)
        #expect(message.subject == nil)
        #expect(message.labels.isEmpty)
        #expect(message.receivedAt == .distantPast)
        #expect(!message.hasListUnsubscribeHeader)
    }

    @Test("Header names are matched case-insensitively")
    func matchesHeadersCaseInsensitively() throws {
        let raw = """
        { "id": "m-case", "payload": { "headers": [
            { "name": "FROM", "value": "alerts@example.org" },
            { "name": "subject", "value": "Lowercased header name" },
            { "name": "list-unsubscribe", "value": "<mailto:unsub@example.org>" }
        ] } }
        """
        let message = GmailMessageNormalizer.normalize(
            try GmailFixtures.decodeMessage(GmailFixtures.SyntheticMessage(id: "m-case", rawJSON: raw))
        )

        #expect(message.sender.address == "alerts@example.org")
        #expect(message.subject == "Lowercased header name")
        #expect(message.hasListUnsubscribeHeader)
    }

    @Test("Encoded subjects are decoded")
    func decodesSubject() throws {
        let dto = try GmailFixtures.decodeMessage(
            GmailFixtures.SyntheticMessage(id: "m-enc", subject: "=?UTF-8?B?Q2Fmw6k=?= news")
        )
        #expect(GmailMessageNormalizer.normalize(dto).subject == "Café news")
    }

    @Test("An empty subject is absent rather than blank")
    func treatsBlankSubjectAsAbsent() throws {
        let dto = try GmailFixtures.decodeMessage(
            GmailFixtures.SyntheticMessage(id: "m-blank", subject: "   ")
        )
        #expect(GmailMessageNormalizer.normalize(dto).subject == nil)
    }

    // MARK: - Dates

    @Test("Gmail's internalDate wins over the sender-supplied Date header")
    func prefersInternalDate() {
        let date = GmailMessageNormalizer.receivedDate(
            internalDate: "1700000000000",
            dateHeader: "Tue, 1 Jan 1980 00:00:00 +0000"
        )
        #expect(date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("The Date header is used when internalDate is missing or unusable", arguments: [
        nil, "", "not-a-number", "0",
    ] as [String?])
    func fallsBackToDateHeader(internalDate: String?) {
        let date = GmailMessageNormalizer.receivedDate(
            internalDate: internalDate,
            dateHeader: "Wed, 15 Nov 2023 22:13:20 +0000"
        )
        #expect(date == Date(timeIntervalSince1970: 1_700_086_400))
    }

    @Test("A message with no usable date sorts to the far past rather than to now")
    func fallsBackToDistantPast() {
        // Defaulting to "now" would make undated mail look like the newest in the mailbox.
        #expect(GmailMessageNormalizer.receivedDate(internalDate: nil, dateHeader: "gibberish") == .distantPast)
    }
}

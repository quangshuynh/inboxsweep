import Foundation
import Testing
@testable import InboxSweep

/// The factual observations a summary carries beyond its counts.
///
/// Every case here is checking that the app *reports* something the mailbox already said,
/// a label Gmail applied, a header that was present, a gap between two dates, and that it
/// stops there.
@Suite("Sender observations")
struct SenderObservationTests {

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 86_400

    private func message(
        _ id: String,
        from: String = "news@example.com",
        hoursAfterEpoch: Double = 0,
        labels: Set<MailLabel> = [.inbox],
        listUnsubscribe: Bool = false,
        receivedAt: Date? = nil
    ) -> MailMessage {
        MailMessage(
            id: MailMessageID(id),
            sender: EmailAddressParser.parse(from),
            subject: "Subject \(id)",
            receivedAt: receivedAt ?? Self.epoch.addingTimeInterval(hoursAfterEpoch * Self.hour),
            labels: labels,
            hasListUnsubscribeHeader: listUnsubscribe
        )
    }

    // MARK: - Gmail categories

    @Test("A sender's categories are the union of the ones its loaded messages carry")
    func collectsCategoryLabels() throws {
        let summaries = SenderAggregator.aggregate([
            message("1", labels: [.inbox, .categoryPromotions]),
            message("2", labels: [.inbox, .categoryUpdates, .unread]),
            message("3", labels: [.inbox, .categoryPromotions]),
        ])

        let summary = try #require(summaries.first)
        #expect(summary.categoryLabels == [.categoryPromotions, .categoryUpdates])
    }

    @Test("Labels that are not categories are not reported as categories")
    func ignoresNonCategoryLabels() throws {
        let summaries = SenderAggregator.aggregate([
            message("1", labels: [.inbox, .unread, .starred, .important, .other("Label_42")]),
        ])

        #expect(try #require(summaries.first).categoryLabels.isEmpty)
    }

    @Test("A sender with no categories reports none rather than guessing one")
    func reportsNoCategoryWhenGmailAppliedNone() throws {
        let summaries = SenderAggregator.aggregate([message("1", labels: [.inbox])])
        let summary = try #require(summaries.first)

        #expect(summary.categoryLabels.isEmpty)
        #expect(summary.orderedCategoryLabels.isEmpty)
    }

    @Test("Categories are listed in a fixed order, so they read the same every time")
    func ordersCategoriesStably() throws {
        let summaries = SenderAggregator.aggregate([
            message("1", labels: [.inbox, .categorySocial]),
            message("2", labels: [.inbox, .categoryPersonal]),
            message("3", labels: [.inbox, .categoryPromotions]),
        ])

        let summary = try #require(summaries.first)
        #expect(summary.orderedCategoryLabels == [.categoryPersonal, .categoryPromotions, .categorySocial])
    }

    // MARK: - List-Unsubscribe

    @Test("The List-Unsubscribe header is counted, not acted on")
    func countsUnsubscribeHeaders() throws {
        let summaries = SenderAggregator.aggregate([
            message("1", listUnsubscribe: true),
            message("2", listUnsubscribe: false),
            message("3", listUnsubscribe: true),
        ])

        let summary = try #require(summaries.first)
        #expect(summary.listUnsubscribeCount == 2)
        #expect(summary.hasListUnsubscribeHeader)
    }

    @Test("A sender whose mail never carried the header reports zero")
    func reportsAbsentUnsubscribeHeader() throws {
        let summaries = SenderAggregator.aggregate([message("1"), message("2")])
        let summary = try #require(summaries.first)

        #expect(summary.listUnsubscribeCount == 0)
        #expect(!summary.hasListUnsubscribeHeader)
    }

    // MARK: - Cadence

    @Test("Frequency is the mean gap between the loaded messages")
    func measuresCadence() throws {
        // Four messages, two days apart: three gaps across a six-day span.
        let summaries = SenderAggregator.aggregate((0..<4).map {
            message("m\($0)", hoursAfterEpoch: Double($0) * 48)
        })

        #expect(try #require(summaries.first).averageIntervalBetweenLoadedMessages == 2 * Self.day)
    }

    @Test("Input order does not change the measured frequency")
    func cadenceIsOrderIndependent() {
        let messages = (0..<5).map { message("m\($0)", hoursAfterEpoch: Double($0) * 12) }

        let forward = SenderAggregator.aggregate(messages)[0]
        let reversed = SenderAggregator.aggregate(messages.reversed())[0]

        #expect(forward.averageIntervalBetweenLoadedMessages == reversed.averageIntervalBetweenLoadedMessages)
    }

    @Test("One message is not a frequency")
    func reportsNoCadenceForASingleMessage() throws {
        let summaries = SenderAggregator.aggregate([message("only", hoursAfterEpoch: 4)])
        #expect(try #require(summaries.first).averageIntervalBetweenLoadedMessages == nil)
    }

    @Test("Messages that all arrived at the same instant are not a frequency either")
    func reportsNoCadenceWithoutASpan() throws {
        let summaries = SenderAggregator.aggregate([
            message("1", hoursAfterEpoch: 4),
            message("2", hoursAfterEpoch: 4),
        ])

        #expect(try #require(summaries.first).averageIntervalBetweenLoadedMessages == nil)
    }

    @Test("A message the normalizer couldn't date is left out of the frequency")
    func cadenceIgnoresUndatedMessages() throws {
        // A dateless message lands on `.distantPast`. Letting it into the span would report
        // this sender as writing once every few thousand years.
        let summaries = SenderAggregator.aggregate([
            message("dated-1", hoursAfterEpoch: 0),
            message("dated-2", hoursAfterEpoch: 24),
            message("dated-3", hoursAfterEpoch: 48),
            message("undated", receivedAt: .distantPast),
        ])

        let summary = try #require(summaries.first)
        #expect(summary.averageIntervalBetweenLoadedMessages == Self.day)
        // The undated message still counts as a message and still widens the loaded span.
        #expect(summary.messageCount == 4)
        #expect(summary.oldestLoadedReceivedAt == .distantPast)
    }

    @Test("A sender with only undated messages has no frequency rather than a nonsensical one")
    func reportsNoCadenceWhenNothingIsDated() throws {
        let summaries = SenderAggregator.aggregate([
            message("1", receivedAt: .distantPast),
            message("2", receivedAt: .distantPast),
        ])

        #expect(try #require(summaries.first).averageIntervalBetweenLoadedMessages == nil)
    }

    // MARK: - Boundary

    @Test("Observations do not become a judgement about the sender")
    func observationsCarryNoVerdict() {
        // The same guarantee `SafetyBoundaryTests` makes, restated for the fields added here:
        // these are counts and labels, and there is nowhere for a score to live.
        let summary = SenderAggregator.aggregate([
            message("1", labels: [.inbox, .categoryPromotions], listUnsubscribe: true),
            message("2", labels: [.inbox, .categoryPromotions], listUnsubscribe: true),
        ])[0]

        let propertyNames = Set(Mirror(reflecting: summary).children.compactMap(\.label))
        let judgementNames: Set<String> = [
            "score", "isUseless", "isNewsletter", "category", "recommendation",
            "cleanupScore", "isBulk", "isSpam", "shouldUnsubscribe",
        ]

        #expect(propertyNames.isDisjoint(with: judgementNames))
    }
}

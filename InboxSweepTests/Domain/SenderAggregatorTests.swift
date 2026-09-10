import Foundation
import Testing
@testable import InboxSweep

@Suite("Sender aggregation")
struct SenderAggregatorTests {

    // MARK: - Helpers

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func message(
        _ id: String,
        from: String?,
        hoursAfterEpoch: Double = 0,
        subject: String? = nil,
        labels: Set<MailLabel> = [.inbox]
    ) -> MailMessage {
        MailMessage(
            id: MailMessageID(id),
            sender: EmailAddressParser.parse(from),
            subject: subject,
            receivedAt: Self.epoch.addingTimeInterval(hoursAfterEpoch * 3600),
            labels: labels
        )
    }

    // MARK: - Grouping

    @Test("Messages from one sender collapse into a single summary")
    func groupsOneSender() {
        let summaries = SenderAggregator.aggregate([
            message("1", from: "Newsletter <newsletter@example.com>"),
            message("2", from: "NEWSLETTER@EXAMPLE.COM"),
            message("3", from: "  newsletter@example.com  "),
        ])

        #expect(summaries.count == 1)
        #expect(summaries[0].messageCount == 3)
        #expect(summaries[0].sender.address == "newsletter@example.com")
    }

    @Test("Distinct senders stay distinct")
    func separatesSenders() {
        let summaries = SenderAggregator.aggregate([
            message("1", from: "newsletter@example.com"),
            message("2", from: "alerts@example.org"),
            message("3", from: "person@example.net"),
        ])

        #expect(summaries.count == 3)
        #expect(Set(summaries.map(\.sender.address)) == [
            "newsletter@example.com", "alerts@example.org", "person@example.net",
        ])
    }

    @Test("An empty window aggregates to nothing rather than failing")
    func handlesEmptyInput() {
        #expect(SenderAggregator.aggregate([]).isEmpty)
    }

    // MARK: - Counts

    @Test("Unread, starred, and important are counted independently")
    func countsFlags() throws {
        let summaries = SenderAggregator.aggregate([
            message("1", from: "alerts@example.org", labels: [.inbox, .unread]),
            message("2", from: "alerts@example.org", labels: [.inbox, .unread, .starred]),
            message("3", from: "alerts@example.org", labels: [.inbox, .important]),
            message("4", from: "alerts@example.org", labels: [.inbox]),
        ])

        let summary = try #require(summaries.first)
        #expect(summary.messageCount == 4)
        #expect(summary.unreadCount == 2)
        #expect(summary.starredCount == 1)
        #expect(summary.importantCount == 1)
        #expect(!summary.isEntirelyUnread)
    }

    @Test("A sender whose loaded mail is all unread is flagged as such")
    func detectsFullyUnreadSender() {
        let summaries = SenderAggregator.aggregate([
            message("1", from: "deals@example.com", labels: [.inbox, .unread]),
            message("2", from: "deals@example.com", labels: [.inbox, .unread]),
        ])

        #expect(summaries[0].isEntirelyUnread)
    }

    // MARK: - Dates

    @Test("Newest and oldest span the loaded window regardless of input order")
    func tracksDateRange() {
        let summaries = SenderAggregator.aggregate([
            message("2", from: "alerts@example.org", hoursAfterEpoch: 50),
            message("1", from: "alerts@example.org", hoursAfterEpoch: 10),
            message("3", from: "alerts@example.org", hoursAfterEpoch: 30),
        ])

        let summary = summaries[0]
        #expect(summary.newestReceivedAt == Self.epoch.addingTimeInterval(50 * 3600))
        #expect(summary.oldestLoadedReceivedAt == Self.epoch.addingTimeInterval(10 * 3600))
    }

    // MARK: - Display name selection

    @Test("The display name comes from the sender's newest message")
    func picksNewestDisplayName() {
        let summaries = SenderAggregator.aggregate([
            message("1", from: "Old Name <news@example.com>", hoursAfterEpoch: 1),
            message("2", from: "New Name <news@example.com>", hoursAfterEpoch: 9),
            message("3", from: "news@example.com", hoursAfterEpoch: 20),
        ])

        // The newest message has no display name at all, so the newest one that *does* wins.
        #expect(summaries[0].sender.displayName == "New Name")
    }

    @Test("Input order never changes the result")
    func aggregationIsOrderIndependent() {
        let messages = [
            message("a", from: "One <one@example.com>", hoursAfterEpoch: 3, subject: "A"),
            message("b", from: "one@example.com", hoursAfterEpoch: 3, subject: "B"),
            message("c", from: "Two <two@example.org>", hoursAfterEpoch: 1, subject: "C"),
            message("d", from: nil, hoursAfterEpoch: 2, subject: "D"),
        ]

        let forward = SenderAggregator.aggregate(messages)
        let reversed = SenderAggregator.aggregate(messages.reversed())
        let shuffled = SenderAggregator.aggregate([messages[2], messages[0], messages[3], messages[1]])

        #expect(forward == reversed)
        #expect(forward == shuffled)
    }

    // MARK: - Unknown senders

    @Test("Every unparseable sender lands in one anonymous bucket")
    func groupsUnknownSenders() {
        let summaries = SenderAggregator.aggregate([
            message("1", from: nil),
            message("2", from: "(no sender)"),
            message("3", from: "Mail Delivery Subsystem"),
            message("4", from: ""),
        ])

        #expect(summaries.count == 1)
        let summary = summaries[0]
        #expect(summary.messageCount == 4)
        #expect(summary.id == EmailAddress.unknownGroupingKey)
        // The bucket holds several genuinely different senders, so it must not adopt one of
        // their names and present itself as that sender.
        #expect(summary.sender.displayName == nil)
        #expect(summary.sender.displayValue == "Unknown sender")
    }

    // MARK: - Subjects

    @Test("Recent subjects are newest-first, bounded, and skip empty ones")
    func collectsRecentSubjects() {
        let summaries = SenderAggregator.aggregate(
            [
                message("1", from: "news@example.com", hoursAfterEpoch: 1, subject: "Oldest"),
                message("2", from: "news@example.com", hoursAfterEpoch: 2, subject: nil),
                message("3", from: "news@example.com", hoursAfterEpoch: 3, subject: "Middle"),
                message("4", from: "news@example.com", hoursAfterEpoch: 4, subject: "Newer"),
                message("5", from: "news@example.com", hoursAfterEpoch: 5, subject: "Newest"),
            ],
            recentSubjectLimit: 3
        )

        #expect(summaries[0].recentSubjects == ["Newest", "Newer", "Middle"])
    }

    // MARK: - Sorting

    @Test("Volume sorting puts the loudest sender first")
    func sortsByVolume() {
        let summaries = SenderAggregator.aggregate(
            volumeFixture(),
            sortedBy: .messageVolume
        )

        #expect(summaries.map(\.messageCount) == [3, 2, 1])
        #expect(summaries[0].sender.address == "loud@example.com")
    }

    @Test("Each sort order leads with the field it names")
    func sortOrdersLeadWithTheirField() {
        let messages = volumeFixture()

        #expect(SenderAggregator.aggregate(messages, sortedBy: .unreadVolume)[0].sender.address == "unread@example.org")
        #expect(SenderAggregator.aggregate(messages, sortedBy: .mostRecent)[0].sender.address == "recent@example.net")
        #expect(SenderAggregator.aggregate(messages, sortedBy: .senderName)[0].sender.displayValue == "Loud Sender")
    }

    @Test("Ties break deterministically, so equal senders never shuffle", arguments: SenderSortOrder.allCases)
    func sortingIsTotal(order: SenderSortOrder) {
        // Three senders that are identical in every sortable field except their address.
        let messages = ["c@example.com", "a@example.com", "b@example.com"].enumerated().map {
            message("tie-\($0.offset)", from: $0.element, hoursAfterEpoch: 5, labels: [.inbox, .unread])
        }

        let first = SenderAggregator.aggregate(messages, sortedBy: order)
        let second = SenderAggregator.aggregate(messages.reversed(), sortedBy: order)

        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.id) == ["a@example.com", "b@example.com", "c@example.com"])
    }

    @Test("Re-sorting an existing list matches aggregating in that order", arguments: SenderSortOrder.allCases)
    func resortingMatchesAggregation(order: SenderSortOrder) {
        let messages = volumeFixture()
        let aggregated = SenderAggregator.aggregate(messages, sortedBy: order)
        let resorted = SenderAggregator.sort(
            SenderAggregator.aggregate(messages, sortedBy: .senderName),
            by: order
        )

        #expect(aggregated == resorted)
    }

    /// Three senders that lead on different fields: volume, unread count, and recency.
    private func volumeFixture() -> [MailMessage] {
        [
            message("l1", from: "Loud Sender <loud@example.com>", hoursAfterEpoch: 1),
            message("l2", from: "loud@example.com", hoursAfterEpoch: 2),
            message("l3", from: "loud@example.com", hoursAfterEpoch: 3),
            message("u1", from: "Unread Sender <unread@example.org>", hoursAfterEpoch: 1, labels: [.inbox, .unread]),
            message("u2", from: "unread@example.org", hoursAfterEpoch: 2, labels: [.inbox, .unread]),
            message("r1", from: "Recent Sender <recent@example.net>", hoursAfterEpoch: 99),
        ]
    }
}

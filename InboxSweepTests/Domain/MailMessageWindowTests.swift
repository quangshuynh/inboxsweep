import Foundation
import Testing
@testable import InboxSweep

/// How pages of loaded messages combine into one window.
///
/// The behaviour that matters here is what happens when the same message arrives twice,
/// which Gmail does at a page boundary, because every per-sender count the dashboard shows
/// is derived from this window.
@Suite("Mail message window")
struct MailMessageWindowTests {

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func message(
        _ id: String,
        from: String = "news@example.com",
        hours: Double = 0,
        labels: Set<MailLabel> = [.inbox]
    ) -> MailMessage {
        MailMessage(
            id: MailMessageID(id),
            sender: EmailAddressParser.parse(from),
            subject: "Subject \(id)",
            receivedAt: Self.epoch.addingTimeInterval(hours * 3600),
            labels: labels
        )
    }

    // MARK: - Merging pages

    @Test("A page with no overlap is appended in order")
    func appendsDisjointPages() {
        let window = MailMessageWindow.merging(
            [message("1"), message("2")],
            with: [message("3"), message("4")]
        )

        #expect(window.map(\.id.rawValue) == ["1", "2", "3", "4"])
    }

    @Test("A message listed on two pages is kept once")
    func collapsesAMessageSeenTwice() {
        let window = MailMessageWindow.merging(
            [message("1"), message("2"), message("3")],
            with: [message("3"), message("4")]
        )

        #expect(window.map(\.id.rawValue) == ["1", "2", "3", "4"])
    }

    @Test("A duplicate keeps the position it already had, so the list does not reshuffle")
    func keepsTheFirstPosition() {
        let window = MailMessageWindow.merging(
            [message("1"), message("2")],
            with: [message("3"), message("1")]
        )

        #expect(window.map(\.id.rawValue) == ["1", "2", "3"])
    }

    @Test("A duplicate takes the later copy's content, which is the more recent read")
    func adoptsTheLatestCopy() throws {
        let window = MailMessageWindow.merging(
            [message("1", labels: [.inbox, .unread])],
            with: [message("1", labels: [.inbox])]
        )

        #expect(window.count == 1)
        #expect(!(try #require(window.first).isUnread))
    }

    @Test("Merging a page the window already holds changes nothing")
    func mergingIsIdempotent() {
        let page = [message("1"), message("2"), message("3")]
        let once = MailMessageWindow.merging([], with: page)

        #expect(MailMessageWindow.merging(once, with: page) == once)
    }

    @Test("Merging into an empty window is the page itself")
    func mergingIntoNothingIsThePage() {
        let page = [message("1"), message("2")]

        #expect(MailMessageWindow.merging([], with: page) == page)
    }

    @Test("Merging nothing into a window leaves it alone")
    func mergingNothingKeepsTheWindow() {
        let window = [message("1"), message("2")]

        #expect(MailMessageWindow.merging(window, with: []) == window)
    }

    // MARK: - Deduplicating a single window

    @Test("Duplicates inside one window are collapsed under the same rules")
    func deduplicatesOneWindow() throws {
        let window = MailMessageWindow.deduplicated([
            message("1", labels: [.inbox, .unread]),
            message("2"),
            message("1", labels: [.inbox]),
        ])

        #expect(window.map(\.id.rawValue) == ["1", "2"])
        #expect(!(try #require(window.first).isUnread))
    }

    @Test("A window with no duplicates is returned unchanged")
    func leavesACleanWindowAlone() {
        let window = [message("1"), message("2"), message("3")]

        #expect(MailMessageWindow.deduplicated(window) == window)
    }

    // MARK: - What the aggregation sees

    @Test("A message counted once is a sender counted once")
    func mergedWindowDoesNotDoubleCountASender() throws {
        let window = MailMessageWindow.merging(
            [message("1", hours: 2, labels: [.inbox, .unread]), message("2", hours: 1)],
            with: [message("2", hours: 1), message("3", hours: 0)]
        )

        let summary = try #require(SenderAggregator.aggregate(window).first)
        #expect(summary.messageCount == 3)
        #expect(summary.unreadCount == 1)
    }
}

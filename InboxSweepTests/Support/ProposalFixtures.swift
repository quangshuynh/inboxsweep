import Foundation
@testable import InboxSweep

/// Synthetic senders for the proposal, protection, and planning tests.
///
/// Every address is in an RFC 2606 reserved domain and every subject is invented. Dates are
/// anchored to a fixed epoch rather than `Date()` so the same test run produces the same
/// cadences, spans, and cutoffs on any day.
nonisolated enum ProposalFixtures {

    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86_400

    /// Builds a run of messages from one sender, newest at `epoch` and spaced `hoursApart`.
    ///
    /// - Parameters:
    ///   - subjects: One subject per message; its count sets the run length.
    ///   - unreadCount: How many of the newest messages are unread.
    ///   - starredCount: How many of the newest messages are starred.
    ///   - importantCount: How many of the newest messages are marked Important.
    static func messages(
        from address: String,
        subjects: [String],
        hoursApart: Double = 24,
        labels: Set<MailLabel> = [.inbox],
        listUnsubscribe: Bool = false,
        unreadCount: Int = 0,
        starredCount: Int = 0,
        importantCount: Int = 0,
        idPrefix: String = "m"
    ) -> [MailMessage] {
        subjects.enumerated().map { index, subject in
            var messageLabels = labels
            if index < unreadCount { messageLabels.insert(.unread) }
            if index < starredCount { messageLabels.insert(.starred) }
            if index < importantCount { messageLabels.insert(.important) }

            return MailMessage(
                id: MailMessageID(String(format: "\(idPrefix)-%03d", index)),
                sender: EmailAddressParser.parse(address),
                subject: subject,
                receivedAt: epoch.addingTimeInterval(-hoursApart * hour * Double(index)),
                labels: messageLabels,
                hasListUnsubscribeHeader: listUnsubscribe
            )
        }
    }

    /// Numbered subjects that match no topic list, for senders whose *shape* is under test.
    static func neutralSubjects(_ count: Int, prefix: String = "Update") -> [String] {
        (1...count).map { "\(prefix) \($0)" }
    }

    /// The evidence the engine sees for a run of messages.
    static func evidence(for messages: [MailMessage]) -> SenderEvidence {
        let summary = SenderAggregator.aggregate(messages)[0]
        return SenderEvidenceBuilder.build(summary: summary, messages: messages)
    }

    /// The proposal for a run of messages.
    static func proposal(
        for messages: [MailMessage],
        rules: CleanupProposalRules = .default
    ) -> SenderCleanupProposal {
        CleanupProposalEngine.evaluate(evidence(for: messages), rules: rules)
    }

    // MARK: - Named senders

    /// High volume, Gmail Promotions, unsubscribe metadata, entirely unread.
    static func promotionalSender(count: Int = 24) -> [MailMessage] {
        messages(
            from: "Storefront Deals <deals@example.com>",
            subjects: neutralSubjects(count, prefix: "Weekend sale"),
            hoursApart: 20,
            labels: [.inbox, .categoryPromotions],
            listUnsubscribe: true,
            unreadCount: count
        )
    }

    /// A mailing list: unsubscribe metadata, weekly cadence, long history, some read.
    static func newsletterSender(count: Int = 14) -> [MailMessage] {
        messages(
            from: "\"Frontend Weekly\" <list@example.org>",
            subjects: neutralSubjects(count, prefix: "Frontend Weekly issue"),
            hoursApart: 24 * 7,
            labels: [.inbox, .categoryUpdates],
            listUnsubscribe: true,
            unreadCount: count / 4
        )
    }

    /// Automated status mail: machine local part, steady cadence, no list metadata.
    static func notificationSender(count: Int = 16) -> [MailMessage] {
        messages(
            from: "notifications@example.net",
            subjects: neutralSubjects(count, prefix: "Backup completed"),
            hoursApart: 26,
            labels: [.inbox, .categoryUpdates],
            unreadCount: count
        )
    }

    /// Too little mail to say anything about, but otherwise shaped like bulk mail.
    static func lowVolumeSender(count: Int = 3) -> [MailMessage] {
        messages(
            from: "bulletin@example.org",
            subjects: neutralSubjects(count, prefix: "This week at the café"),
            hoursApart: 24 * 7,
            listUnsubscribe: true,
            unreadCount: count
        )
    }
}

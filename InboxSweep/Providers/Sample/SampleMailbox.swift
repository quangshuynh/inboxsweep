#if DEBUG
import Foundation

/// Synthetic mailbox content for development, previews, and UI tests.
///
/// All addresses use the RFC 2606 reserved domains (`example.com`, `example.org`,
/// `example.net`), which can never belong to anyone. No part of this file is derived from a
/// real mailbox.
nonisolated enum SampleMailbox {

    static let account = MailAccount(
        emailAddress: EmailAddress(displayName: "Sample User", address: "sample.user@example.com"),
        providerDisplayName: "Sample data"
    )

    /// Builds a mailbox whose shape resembles a real one: a few high-volume automated senders,
    /// a long tail of quiet ones, and one message with an unparseable `From` header.
    static func messages(relativeTo now: Date = Date()) -> [MailMessage] {
        var messages: [MailMessage] = []
        var sequence = 0

        func add(
            from sender: String,
            subjects: [String],
            hoursAgoStart: Double,
            hoursApart: Double,
            unreadEvery: Int? = nil,
            starredEvery: Int? = nil,
            importantEvery: Int? = nil,
            labels: Set<MailLabel> = [.inbox],
            listUnsubscribe: Bool = false
        ) {
            for (index, subject) in subjects.enumerated() {
                sequence += 1
                var messageLabels = labels
                if let unreadEvery, index % unreadEvery == 0 { messageLabels.insert(.unread) }
                if let starredEvery, index % starredEvery == 0 { messageLabels.insert(.starred) }
                if let importantEvery, index % importantEvery == 0 { messageLabels.insert(.important) }

                messages.append(
                    MailMessage(
                        id: MailMessageID(String(format: "sample-%04d", sequence)),
                        threadID: MailThreadID(String(format: "thread-%04d", sequence)),
                        sender: EmailAddressParser.parse(sender),
                        subject: subject,
                        receivedAt: now.addingTimeInterval(-3600 * (hoursAgoStart + hoursApart * Double(index))),
                        labels: messageLabels,
                        hasListUnsubscribeHeader: listUnsubscribe
                    )
                )
            }
        }

        add(
            from: "\"The Daily Digest\" <newsletter@example.com>",
            subjects: (1...18).map { "The Daily Digest — issue \(120 + $0)" },
            hoursAgoStart: 2,
            hoursApart: 24,
            unreadEvery: 2,
            labels: [.inbox, .categoryPromotions],
            listUnsubscribe: true
        )

        add(
            from: "Storefront Deals <deals@example.com>",
            subjects: [
                "48 hours only: everything must go",
                "Your cart is waiting",
                "Weekend flash sale",
                "New arrivals you'll love",
                "Last chance for free shipping",
                "A little something for you",
                "Members-only pricing ends tonight",
                "We saved your size",
                "Back in stock",
                "Your exclusive code inside",
                "Extra 20% off, today only",
                "Did you forget something?",
            ],
            hoursAgoStart: 5,
            hoursApart: 17,
            unreadEvery: 1,
            labels: [.inbox, .categoryPromotions],
            listUnsubscribe: true
        )

        add(
            from: "alerts@example.org",
            subjects: (1...9).map { "Build #\(4200 + $0) finished" },
            hoursAgoStart: 1,
            hoursApart: 9,
            unreadEvery: 3,
            importantEvery: 4,
            labels: [.inbox, .categoryUpdates]
        )

        add(
            from: "Jordan Avery <person@example.net>",
            subjects: [
                "Re: dinner on Thursday?",
                "Photos from the weekend",
                "Quick question about the trip",
                "Re: dinner on Thursday?",
            ],
            hoursAgoStart: 3,
            hoursApart: 40,
            starredEvery: 2,
            importantEvery: 2,
            labels: [.inbox, .categoryPersonal]
        )

        add(
            from: "=?UTF-8?Q?Caf=C3=A9_Bulletin?= <bulletin@example.org>",
            subjects: ["This week at the café", "Opening hours are changing", "New seasonal menu"],
            hoursAgoStart: 12,
            hoursApart: 168,
            unreadEvery: 3,
            listUnsubscribe: true
        )

        add(
            from: "no-reply@example.net",
            subjects: ["Your monthly statement is ready", "Security alert: new sign-in"],
            hoursAgoStart: 30,
            hoursApart: 720,
            importantEvery: 1
        )

        add(
            from: "Conference Committee <hello@example.org>",
            subjects: ["Your talk proposal was received"],
            hoursAgoStart: 96,
            hoursApart: 1
        )

        // A header with no parseable address, so the "unknown sender" path is visible during
        // development instead of only appearing against a real mailbox.
        add(
            from: "(no sender)",
            subjects: ["Delivery status notification"],
            hoursAgoStart: 60,
            hoursApart: 1,
            unreadEvery: 1
        )

        return messages
    }
}
#endif

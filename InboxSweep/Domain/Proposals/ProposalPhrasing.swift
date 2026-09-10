import Foundation

/// The small amount of English the proposal layer needs to write countable phrases.
///
/// Reasons are built in the domain, not the UI, because they are the *output* of the rules —
/// a reason the UI had to assemble would be a rule living in a view. That means the domain
/// has to pluralize, and this is the whole of what it needs to do so.
///
/// Deliberately not localized. The rest of the app is not localized either, and pretending
/// otherwise here would add a translation surface with nothing behind it.
nonisolated enum ProposalPhrasing {

    /// "1 loaded message" / "7 loaded messages".
    static func loadedMessages(_ count: Int) -> String {
        count == 1 ? "1 loaded message" : "\(count) loaded messages"
    }

    /// "1 message" / "7 messages".
    static func messages(_ count: Int) -> String {
        count == 1 ? "1 message" : "\(count) messages"
    }

    /// The verb that agrees with a count of `count`.
    static func isAre(_ count: Int) -> String {
        count == 1 ? "is" : "are"
    }

    /// The verb that agrees with a count of `count`, for verbs inflected like "look".
    static func looksLook(_ count: Int) -> String {
        count == 1 ? "looks" : "look"
    }

    /// Renders a mean interval between messages as a rounded, hedged cadence phrase.
    ///
    /// "About 3 messages per week" reads as an observation; "every 56.2 hours" reads as a
    /// measurement the app cannot actually support, since it is a mean over a window that the
    /// user can extend at any time. Returns `nil` when there is no interval to describe.
    static func cadence(everySeconds interval: TimeInterval?) -> String? {
        guard let interval, interval > 0 else { return nil }

        let hour: TimeInterval = 3600
        let day: TimeInterval = 86_400
        let week: TimeInterval = 7 * day
        let month: TimeInterval = 30 * day

        // Pick the largest unit that yields at least one message per period, so a daily sender
        // is described per day and a quarterly one is not described as "0 per week".
        for (period, name) in [(day, "day"), (week, "week"), (month, "month")] {
            let perPeriod = (period / interval).rounded()
            if perPeriod >= 1 {
                return perPeriod == 1
                    ? "About 1 message per \(name)"
                    : "About \(Int(perPeriod)) messages per \(name)"
            }
        }

        let months = (interval / month).rounded()
        if months >= 1 {
            return months == 1 ? "About 1 message per month" : "About one message every \(Int(months)) months"
        }
        // Sub-hourly senders fall through to the finest phrasing available.
        let perHour = max(1, Int((hour / interval).rounded()))
        return perHour == 1 ? "About 1 message per hour" : "About \(perHour) messages per hour"
    }

    /// "over about 4 months" — how much history the loaded window covers.
    ///
    /// Returns `nil` for spans under a day, where "over about 0 months" would say nothing.
    static func windowSpan(_ span: TimeInterval) -> String? {
        let day: TimeInterval = 86_400
        guard span >= day else { return nil }

        let days = Int((span / day).rounded())
        if days < 14 { return days == 1 ? "about 1 day" : "about \(days) days" }

        let weeks = Int((span / (7 * day)).rounded())
        if weeks < 9 { return "about \(weeks) weeks" }

        let months = Int((span / (30 * day)).rounded())
        if months < 18 { return months == 1 ? "about 1 month" : "about \(months) months" }

        let years = (span / (365 * day) * 10).rounded() / 10
        return years == 1 ? "about 1 year" : "about \(years.formatted(.number.precision(.fractionLength(0...1)))) years"
    }
}

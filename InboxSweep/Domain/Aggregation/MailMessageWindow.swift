import Foundation

/// Combines pages of loaded messages into the single window the app reasons about.
///
/// Pagination is the reason this exists. Gmail's list endpoint can return the same message ID
/// on two consecutive pages, because mail arriving while the user reads shifts the page
/// boundary, and a window that simply appended each page would count that message twice: twice in the
/// sender's total, twice in its unread count, and twice in the mean gap between its messages.
/// The fetcher already removes duplicates *within* one page; this removes them *across* pages,
/// and across the boundary between a window restored from disk and the pages added to it.
///
/// Pure, synchronous, and deterministic, like ``SenderAggregator``: the same pages in the same
/// sequence always produce the same window, so the dashboard derived from it is reproducible.
nonisolated enum MailMessageWindow {

    /// Merges `incoming` into `existing`, keeping one entry per provider message ID.
    ///
    /// Two rules, both chosen so a merge is predictable rather than merely duplicate-free:
    ///
    /// - **Position is the first one seen.** A message already in the window stays where it
    ///   is, so extending a window never reorders the rows the user is already looking at.
    /// - **Content is the last one seen.** The later copy is the more recent read of the same
    ///   message, so one that was marked read in Gmail since the first page loaded shows up as
    ///   read rather than keeping its stale labels.
    ///
    /// Merging is therefore idempotent: merging in a page the window already holds returns
    /// that window unchanged.
    static func merging(_ existing: [MailMessage], with incoming: [MailMessage]) -> [MailMessage] {
        deduplicated(existing + incoming)
    }

    /// The window with duplicate IDs collapsed, under the same two rules as ``merging(_:with:)``.
    ///
    /// Applied to a window read back from disk as well as to fetched pages: a cache file
    /// written by an earlier build, or hand-edited, must not put duplicates into the
    /// aggregation either.
    static func deduplicated(_ messages: [MailMessage]) -> [MailMessage] {
        var window: [MailMessage] = []
        window.reserveCapacity(messages.count)

        var positions: [MailMessageID: Int] = [:]
        positions.reserveCapacity(messages.count)

        for message in messages {
            if let position = positions[message.id] {
                window[position] = message
            } else {
                positions[message.id] = window.count
                window.append(message)
            }
        }

        return window
    }
}

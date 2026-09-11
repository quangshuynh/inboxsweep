import Foundation

/// Every threshold the proposal engine uses, in one reviewable place.
///
/// Thresholds live in a value rather than as literals inside the rules so that they can be
/// read end to end, varied in a test without rewriting the engine, and, most importantly,
/// argued with. A heuristic whose numbers are scattered through the code it drives is a
/// heuristic nobody can check.
///
/// The numbers themselves are judgement calls about *bulk mail*, not about the user. None of
/// them is tuned against a real mailbox, and none of them is claimed to be optimal.
nonisolated struct CleanupProposalRules: Hashable, Sendable {

    /// Bumped whenever the rules change in a way that would produce different proposals.
    ///
    /// Proposals are never persisted: they are recomputed from stored message metadata on
    /// every launch, so this is not a migration key. It is carried on each proposal so the UI
    /// and the tests can state which ruleset produced what they are showing.
    static let version = 1

    /// Messages from one sender in the loaded window before volume counts as a signal.
    var highVolumeMessageCount = 8

    /// Below this many loaded messages, no cleanup-oriented proposal is made at all.
    ///
    /// Not because such senders are precious, but because four messages cannot distinguish a
    /// mailing list from a colleague who happened to write four times.
    var minimumMessagesForCleanupProposal = 5

    /// Share of a sender's loaded messages that must carry `List-Unsubscribe` before the mail
    /// is treated as list traffic. Below 1.0 because a sender can change platforms mid-window.
    var listMetadataShare = 0.6

    /// Share of a sender's loaded messages that must still be unread to count as unengaged.
    var unreadShare = 0.7

    /// Loaded messages needed before a mean interval is treated as a cadence.
    ///
    /// Two messages produce an interval; they do not produce a rhythm.
    var minimumMessagesForCadence = 4

    /// The band of mean intervals that reads as "recurring": roughly six-hourly to monthly.
    ///
    /// Faster than the lower bound is usually a burst rather than a schedule; slower than the
    /// upper bound is too sparse for the loaded window to say anything about.
    var recurringInterval: ClosedRange<TimeInterval> = (6 * 3600)...(45 * 86_400)

    /// How much history the loaded messages must span to count as a long-running relationship.
    var wideWindowSpan: TimeInterval = 30 * 86_400

    /// Corroborating signals needed for ``ProposalStrength/moderate`` and ``ProposalStrength/strong``.
    var moderateStrengthSignalCount = 4
    var strongStrengthSignalCount = 6

    /// Signals needed before an unclassified sender is proposed as a cleanup candidate.
    var signalsForCleanupCandidate = 4

    /// Signals needed before an otherwise unremarkable sender is worth a look.
    var signalsForReview = 2

    /// Bulk-mail signals needed before a *protected* sender is still worth reviewing.
    ///
    /// Protection normally ends in "keep". This is the exception: when a protected sender is
    /// also unmistakably bulk mail (a shop that sends forty offers and two order receipts)
    /// "keep" would hide something the user probably does want to look at. "Review" says there
    /// is something here without suggesting anything be removed.
    var signalsForProtectedReview = 4

    static let `default` = CleanupProposalRules()
}

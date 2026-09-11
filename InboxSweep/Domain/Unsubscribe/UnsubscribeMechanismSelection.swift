import Foundation

/// Which mechanism InboxSweep offers when a sender's metadata names more than one, and in
/// what order the rest are listed.
///
/// ### The rules
///
/// 1. **Standards-based one-click HTTPS**, when — and only when — both headers agreed.
/// 2. **Ordinary HTTPS web unsubscribe**, the first such URL in header order.
/// 3. **Mail handoff**, the first `mailto` in header order.
///
/// Ties inside each tier are broken by **header order**: the first value the sender listed
/// wins. Not shortest, not "most official-looking", not by host — header order is the only
/// ordering the sender actually expressed, and any other rule would be InboxSweep deciding
/// which of somebody's own endpoints it prefers.
///
/// ### Deterministic, and never silent
///
/// Determinism matters because the same mail must produce the same offer on every launch, or
/// a user's second look at a sender contradicts their first. But choosing well is not enough:
/// the review sheet lists ``UnsubscribeSelection/alternatives`` alongside the choice, so a
/// sender offering a one-click endpoint *and* a web page *and* a mail address shows all three
/// and says which one the button will use. Requirement 19 of this interval is not "choose
/// correctly" — it is "choose visibly".
nonisolated enum UnsubscribeMechanismSelection {

    /// Every mechanism the metadata supports, best first.
    ///
    /// The one-click case does not hide the plain-web one for the same URL: a user who would
    /// rather look at the page than have the app post to it is entitled to that, so the same
    /// URL can appear once as ``UnsubscribeMechanism/oneClick`` and once as
    /// ``UnsubscribeMechanism/webPage``.
    static func mechanisms(in metadata: MessageUnsubscribeMetadata) -> [UnsubscribeMechanism] {
        var mechanisms: [UnsubscribeMechanism] = []

        if let oneClick = metadata.oneClickURL {
            mechanisms.append(.oneClick(oneClick))
        }
        mechanisms += metadata.webURLs.map(UnsubscribeMechanism.webPage)
        mechanisms += metadata.mailAddresses.map(UnsubscribeMechanism.mail)

        return mechanisms
    }

    /// The mechanism to offer, with everything else it could have offered.
    ///
    /// `nil` when the metadata names nothing actionable — which is a state, not a failure.
    static func select(from metadata: MessageUnsubscribeMetadata) -> UnsubscribeSelection? {
        let ordered = mechanisms(in: metadata)
        guard let chosen = ordered.first else { return nil }
        return UnsubscribeSelection(chosen: chosen, alternatives: Array(ordered.dropFirst()))
    }
}

/// What was chosen, and what else was available.
nonisolated struct UnsubscribeSelection: Hashable, Sendable {

    /// The mechanism the confirmation acts on.
    let chosen: UnsubscribeMechanism

    /// Everything else the metadata supported, in the same preference order.
    ///
    /// Shown, not hidden. A sheet that silently picked one of three would be making the user's
    /// decision for them under the name of making it simpler.
    let alternatives: [UnsubscribeMechanism]

    var hasAlternatives: Bool { !alternatives.isEmpty }

    /// Every mechanism, chosen one first.
    var allMechanisms: [UnsubscribeMechanism] { [chosen] + alternatives }

    /// Why this one rather than the others, for the sheet.
    ///
    /// `nil` when there was nothing to choose between, because a sentence explaining a choice
    /// nobody made is noise.
    var selectionRationale: String? {
        guard hasAlternatives else { return nil }
        switch chosen.kind {
        case .oneClick:
            return """
                This sender supports the one-click unsubscribe standard, so that is what InboxSweep \
                offers — it is the only mechanism defined precisely enough for an app to use \
                without guessing. The others are listed below and you can use them instead.
                """
        case .webPage:
            return """
                This sender offers more than one way to unsubscribe. InboxSweep offers the web page \
                because it does not claim one-click support, and a page you can see is preferable to \
                a message InboxSweep would have to compose for you.
                """
        case .mail:
            return """
                The only mechanism this sender offers is an email request, so that is what InboxSweep \
                offers. It prepares the message; sending it is yours to do.
                """
        }
    }
}

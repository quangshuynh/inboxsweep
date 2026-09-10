import Foundation

/// A provider-neutral label or category attached to a message.
///
/// Providers name these differently; the adapter layer is responsible for mapping its own
/// vocabulary onto these cases so that nothing above the provider boundary has to know what
/// a Gmail label ID looks like. Labels the app does not model are preserved as ``other`` so
/// information is never silently discarded.
nonisolated enum MailLabel: Hashable, Sendable {
    case inbox
    case unread
    case starred
    case important
    case sent
    case draft
    case spam
    case trash

    /// Provider-assigned inbox categories, where the provider offers them.
    case categoryPromotions
    case categorySocial
    case categoryUpdates
    case categoryForums
    case categoryPersonal

    /// A label the app does not model, carried through by its provider-side identifier.
    case other(String)

    /// Whether this label is one the app understands, as opposed to a passthrough value.
    var isRecognized: Bool {
        if case .other = self { return false }
        return true
    }

    /// Whether this label is one of the provider's own inbox categories.
    ///
    /// These are the provider's classification, not the app's: InboxSweep reports which
    /// categories a sender's mail already carries and draws no conclusion from them.
    var isCategory: Bool {
        switch self {
        case .categoryPromotions, .categorySocial, .categoryUpdates, .categoryForums, .categoryPersonal:
            true
        case .inbox, .unread, .starred, .important, .sent, .draft, .spam, .trash, .other:
            false
        }
    }

    /// The categories the app models, in the order they are shown.
    ///
    /// A fixed order so a sender's categories read the same way every time rather than in
    /// whatever order a `Set` happens to iterate.
    static let allCategories: [MailLabel] = [
        .categoryPersonal, .categoryUpdates, .categoryPromotions, .categorySocial, .categoryForums,
    ]

    /// A short, human-readable name suitable for display.
    var displayName: String {
        switch self {
        case .inbox: "Inbox"
        case .unread: "Unread"
        case .starred: "Starred"
        case .important: "Important"
        case .sent: "Sent"
        case .draft: "Draft"
        case .spam: "Spam"
        case .trash: "Trash"
        case .categoryPromotions: "Promotions"
        case .categorySocial: "Social"
        case .categoryUpdates: "Updates"
        case .categoryForums: "Forums"
        case .categoryPersonal: "Personal"
        case .other(let identifier): identifier
        }
    }
}

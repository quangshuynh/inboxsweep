import Foundation

/// One fact behind an unsubscribe conclusion.
///
/// Every case below is something the *mailbox* said. A header that was present, a category
/// Gmail applied, a count of messages, a gap between them. There is no case here for "this
/// looks like a newsletter", because that is a judgement and this type is the input to one.
///
/// Subject wording is deliberately absent. A message titled "Newsletter" is not evidence of an
/// unsubscribe mechanism; only the headers are, and requirement 2 of this interval says so in
/// as many words.
nonisolated enum UnsubscribeEvidence: Hashable, Sendable, Identifiable {

    /// The `List-Unsubscribe` header was on this many of the sender's loaded messages.
    case listUnsubscribeHeader(messageCount: Int, ofLoaded: Int)

    /// `List-Unsubscribe-Post: List-Unsubscribe=One-Click` was present alongside an HTTPS URL.
    case oneClickDeclared

    /// The one-click header was there, but there was no HTTPS URL for it to apply to.
    case oneClickDeclaredWithoutURL

    /// The header named more than one usable destination.
    case multipleMechanisms(count: Int)

    /// A value in the header was refused, and why.
    case unusableValue(UnsupportedUnsubscribeValue.Reason)

    /// The sender's own messages disagree about what their unsubscribe metadata is.
    ///
    /// Ordinary for a large sender rotating endpoints, and worth saying: the mechanism shown
    /// comes from one specific message, and this is what tells the user which.
    case metadataVariesAcrossMessages(distinctValues: Int)

    /// Gmail filed this sender's mail under a bulk category.
    case bulkCategory(MailLabel)

    /// The sender arrives repeatedly, at roughly this interval.
    ///
    /// Corroboration only. On its own it says nothing about unsubscribing — a monthly bank
    /// statement recurs too — which is why it can never raise confidence past what the headers
    /// support.
    case recurringSender(messageCount: Int, averageInterval: TimeInterval?)

    var id: String { String(describing: self) }

    /// One sentence, phrased as an observation rather than a conclusion.
    var explanation: String {
        switch self {
        case .listUnsubscribeHeader(let count, let loaded):
            return count == loaded
                ? "Every one of the \(loaded) loaded messages from this sender carries a List-Unsubscribe header"
                : "\(count) of \(loaded) loaded messages from this sender carry a List-Unsubscribe header"

        case .oneClickDeclared:
            return "The sender declares List-Unsubscribe-Post: List-Unsubscribe=One-Click, the RFC 8058 one-click standard"

        case .oneClickDeclaredWithoutURL:
            return "The sender declares one-click support but gives no https link for it to apply to"

        case .multipleMechanisms(let count):
            return "The header names \(count) usable destinations, so there is more than one way to do this"

        case .unusableValue(let reason):
            return "One value in the header is \(reason.explanation)"

        case .metadataVariesAcrossMessages(let distinct):
            return "This sender's loaded messages carry \(distinct) different unsubscribe headers, so the one shown is from one specific message"

        case .bulkCategory(let label):
            return "Gmail files this sender's mail under \(label.displayName)"

        case .recurringSender(let count, let interval):
            guard let interval, let formatted = Self.intervalFormatter.string(from: interval) else {
                return "\(count) messages from this sender are loaded"
            }
            return "\(count) messages loaded, arriving about one every \(formatted)"
        }
    }

    /// Whether this is a reason to be *less* sure, rather than more.
    var isCautionary: Bool {
        switch self {
        case .oneClickDeclaredWithoutURL, .unusableValue, .metadataVariesAcrossMessages: true
        case .listUnsubscribeHeader, .oneClickDeclared, .multipleMechanisms, .bulkCategory, .recurringSender: false
        }
    }

    /// Fixed position in a rendered list, so a sender's evidence reads the same way every time.
    var rank: Int {
        switch self {
        case .listUnsubscribeHeader: 0
        case .oneClickDeclared: 1
        case .multipleMechanisms: 2
        case .bulkCategory: 3
        case .recurringSender: 4
        case .metadataVariesAcrossMessages: 5
        case .oneClickDeclaredWithoutURL: 6
        case .unusableValue: 7
        }
    }

    private static let intervalFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter
    }()
}

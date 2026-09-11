import Foundation

/// A topic a subject line can *suggest*, matched by literal phrase.
///
/// This is the app's only text classification, and it is deliberately the dumbest one that
/// could work: fixed phrase lists, whole-word matching, no scoring, no model, no network. A
/// subject that says "Your order has shipped" is evidence that the message might be an order
/// receipt — it is not proof, and nothing downstream treats it as proof.
///
/// The lists err towards *over*-matching, because every protective topic here can only ever
/// make InboxSweep more cautious about a sender. The one non-protective topic
/// (``promotionalOffer``) never decides anything on its own; see ``CleanupProposalRules``.
nonisolated enum SubjectTopic: String, CaseIterable, Hashable, Sendable, Codable {

    /// Sign-in alerts, verification codes, password changes.
    case accountSecurity

    /// Statements, invoices, payments, banking.
    case financial

    /// Purchase receipts, order confirmations, shipping updates.
    case receiptOrOrder

    /// Bookings, itineraries, boarding passes.
    case travel

    /// Tax, government, and legal correspondence.
    case governmentOrTax

    /// Job applications, interviews, payroll, HR.
    case employment

    /// Appointments, prescriptions, results, claims.
    case healthcare

    /// Discounts, sales, and offers. The only non-protective topic.
    case promotionalOffer

    /// Whether matching this topic is a reason to be *more* careful with a sender.
    ///
    /// Every case except ``promotionalOffer`` is protective, which is why the phrase lists can
    /// afford to be generous: a false positive costs a cleanup suggestion, not a message.
    var isProtective: Bool { self != .promotionalOffer }

    /// A short label for the UI.
    var displayName: String {
        switch self {
        case .accountSecurity: "Account or security"
        case .financial: "Financial"
        case .receiptOrOrder: "Receipts and orders"
        case .travel: "Travel"
        case .governmentOrTax: "Government or tax"
        case .employment: "Employment"
        case .healthcare: "Healthcare"
        case .promotionalOffer: "Offers and discounts"
        }
    }

    /// The phrases that match this topic, as whole words in a normalized subject.
    ///
    /// Phrases only — no regular expressions, no stemming — so what a rule matches is exactly
    /// what is written here and a reviewer can read the whole classifier in one sitting.
    var phrases: [String] {
        switch self {
        case .accountSecurity:
            [
                "security alert", "sign in", "signin", "new device", "new sign in",
                "verify your", "verification code", "confirm your email", "password",
                "two factor", "2fa", "suspicious activity", "unusual activity",
                "account locked", "recovery code", "one time code", "authentication",
            ]
        case .financial:
            [
                "statement", "invoice", "payment", "bank", "balance", "transaction",
                "wire transfer", "direct deposit", "overdraft", "credit card", "debit card",
                "billing", "autopay", "past due", "mortgage", "loan", "premium due",
            ]
        case .receiptOrOrder:
            [
                "receipt", "your order", "order confirmation", "order number", "order has",
                "has shipped", "shipping confirmation", "tracking number", "out for delivery",
                "return label", "refund", "purchase confirmation", "subscription renewal",
            ]
        case .travel:
            [
                "boarding pass", "itinerary", "flight", "reservation", "booking confirmation",
                "hotel confirmation", "check in for", "e ticket", "eticket", "rental car",
                "your trip", "travel confirmation",
            ]
        case .governmentOrTax:
            [
                "tax", "irs", "hmrc", "tax return", "w 2", "1099", "council tax",
                "social security", "jury duty", "court", "dmv", "visa application",
                "passport", "benefits statement",
            ]
        case .employment:
            [
                "offer letter", "interview", "job application", "your application",
                "recruiter", "hiring", "onboarding", "payslip", "pay stub", "payroll",
                "performance review", "resume", "employment", "contract renewal",
            ]
        case .healthcare:
            [
                "appointment", "prescription", "lab results", "test results", "doctor",
                "clinic", "pharmacy", "insurance claim", "medical record", "vaccination",
                "referral", "patient", "explanation of benefits",
            ]
        case .promotionalOffer:
            [
                "sale", "percent off", "discount", "deal", "deals", "coupon", "promo code",
                "free shipping", "limited time", "last chance", "flash sale", "clearance",
                "exclusive offer", "save up to", "buy one", "ends tonight", "members only",
                "black friday", "cyber monday", "new arrivals",
            ]
        }
    }

    /// The topics `subject` suggests, in ``allCases`` order.
    ///
    /// Order is fixed rather than match order so the same subject always produces the same
    /// list — the property the whole engine's determinism rests on.
    static func topics(in subject: String) -> [SubjectTopic] {
        let normalized = normalize(subject)
        guard !normalized.isEmpty else { return [] }
        let padded = " \(normalized) "
        return allCases.filter { topic in
            topic.phrases.contains { padded.contains(" \($0) ") }
        }
    }

    /// Lowercases, spells out `%`, and reduces everything else non-alphanumeric to a single
    /// space, so phrase matching lands on whole words rather than inside them.
    ///
    /// Without this, "reorder" would match "order" and "borders" would match "order" too.
    static func normalize(_ subject: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true

        for scalar in subject.lowercased().unicodeScalars {
            if scalar == "%" {
                // Spelled out so "20% off" can be matched as the phrase "percent off".
                if !lastWasSpace { scalars.append(" ") }
                scalars.append(contentsOf: "percent ".unicodeScalars)
                lastWasSpace = true
                continue
            }

            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                scalars.append(" ")
                lastWasSpace = true
            }
        }

        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }
}

nonisolated extension SubjectTopic {

    /// How this topic is described inside a reason sentence.
    ///
    /// Phrased as what the *subject lines mention*, never as what the mail is. InboxSweep is
    /// matching words, and the wording says so.
    var evidencePhrase: String {
        switch self {
        case .accountSecurity: "sign-in or account-security topics"
        case .financial: "banking, billing, or payment topics"
        case .receiptOrOrder: "receipts, orders, or deliveries"
        case .travel: "travel bookings or itineraries"
        case .governmentOrTax: "tax, government, or legal topics"
        case .employment: "job, recruiting, or payroll topics"
        case .healthcare: "appointments, prescriptions, or medical topics"
        case .promotionalOffer: "sales, discounts, or offers"
        }
    }
}

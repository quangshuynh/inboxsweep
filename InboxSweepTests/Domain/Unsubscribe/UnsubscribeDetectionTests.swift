import Foundation
import Testing
@testable import InboxSweep

/// What InboxSweep concludes about a sender, and (as often) what it refuses to conclude.
@Suite("Unsubscribe detection")
struct UnsubscribeDetectionTests {

    // MARK: - Fixtures

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func message(
        _ id: String,
        from address: String = "news@lists.example",
        hoursAgo: Double = 1,
        labels: Set<MailLabel> = [.inbox],
        subject: String = "Issue 12",
        unsubscribe: MessageUnsubscribeMetadata = .absent
    ) -> MailMessage {
        MailMessage(
            id: MailMessageID(id),
            sender: EmailAddressParser.parse(address),
            subject: subject,
            receivedAt: Self.now.addingTimeInterval(-3600 * hoursAgo),
            labels: labels,
            unsubscribe: unsubscribe
        )
    }

    private func opportunity(
        _ messages: [MailMessage],
        protection: SenderProtectionAssessment = .unprotected
    ) -> UnsubscribeOpportunity {
        let summaries = SenderAggregator.aggregate(messages)
        return UnsubscribeOpportunityBuilder.build(
            sender: summaries[0].sender,
            messages: messages,
            summary: summaries[0],
            protection: protection
        )
    }

    private static func metadata(_ header: String, post: String? = nil) -> MessageUnsubscribeMetadata {
        ListUnsubscribeParser.metadata(listUnsubscribe: header, listUnsubscribePost: post)
    }

    // MARK: - The five states

    @Test("A sender with no header at all reaches no evidence, not a guess")
    func noEvidence() {
        let result = opportunity((1...6).map { message("m\($0)", hoursAgo: Double($0) * 24) })

        #expect(result.availability == .noEvidence)
        #expect(result.confidence == .none)
        #expect(!result.isActionable)
        #expect(result.mechanism == nil)
        #expect(result.unavailableExplanation?.contains("no List-Unsubscribe") == false)
        #expect(result.unavailableExplanation?.contains("never reads") == true)
    }

    @Test("Arriving every day is not evidence of a subscription on its own")
    func recurrenceAloneIsNotEvidence() {
        // The rule that keeps a daily transactional notice from reading as a mailing list.
        // Thirty messages, perfectly regular, filed under a bulk category, and still nothing,
        // because none of them said anything about unsubscribing.
        let messages = (1...30).map {
            message("m\($0)", hoursAgo: Double($0) * 24, labels: [.inbox, .categoryPromotions])
        }

        let result = opportunity(messages)

        #expect(result.availability == .noEvidence)
        #expect(result.confidence == .none)
        #expect(result.evidence.isEmpty)
    }

    @Test("A header that yielded nothing is ambiguous, which is not the same as absent")
    func ambiguousMetadata() {
        let messages = [
            message("m1", unsubscribe: Self.metadata("<http://lists.example/u>, <javascript:go()>")),
            message("m2", hoursAgo: 24),
        ]

        let result = opportunity(messages)

        #expect(result.availability == .ambiguousMetadata)
        #expect(result.confidence == .low)
        #expect(!result.isActionable)
        #expect(result.availability.camesFromListHeader)
        #expect(result.evidence.contains(.unusableValue(.insecureScheme)))
        #expect(result.evidence.contains(.unusableValue(.disallowedScheme)))
        #expect(result.unavailableExplanation?.contains("can't act on it") == true)
    }

    @Test("A one-click endpoint is the only standards-defined state")
    func oneClickAvailable() {
        let messages = (1...4).map {
            message(
                "m\($0)",
                hoursAgo: Double($0) * 24,
                labels: [.inbox, .categoryPromotions],
                unsubscribe: Self.metadata("<https://lists.example/u/abc>", post: "List-Unsubscribe=One-Click")
            )
        }

        let result = opportunity(messages)

        #expect(result.availability == .oneClickAvailable(HTTPSUnsubscribeURL(string: "https://lists.example/u/abc")!))
        #expect(result.confidence == .standardsDefined)
        #expect(result.mechanism?.kind == .oneClick)
        #expect(result.evidence.contains(.oneClickDeclared))
        #expect(result.evidence.contains(.bulkCategory(.categoryPromotions)))
        #expect(result.messagesWithHeader == 4)
    }

    @Test("An HTTPS URL with no one-click declaration is a web page, not a one-click endpoint")
    func webPageAvailable() {
        let result = opportunity([message("m1", unsubscribe: Self.metadata("<https://lists.example/u/abc>"))])

        #expect(result.availability == .webPageAvailable(HTTPSUnsubscribeURL(string: "https://lists.example/u/abc")!))
        #expect(result.confidence == .moderate)
        #expect(result.mechanism?.kind == .webPage)
        #expect(!result.evidence.contains(.oneClickDeclared))
    }

    @Test("A mailto-only sender lands on the mail handoff")
    func mailHandoffAvailable() {
        let result = opportunity([message("m1", unsubscribe: Self.metadata("<mailto:leave@lists.example>"))])

        #expect(result.mechanism?.kind == .mail)
        #expect(result.confidence == .moderate)
        if case .mailHandoffAvailable(let address) = result.availability {
            #expect(address.address == "leave@lists.example")
        } else {
            Issue.record("Expected a mail handoff, got \(result.availability)")
        }
    }

    // MARK: - Which message the mechanism comes from

    @Test("The mechanism comes from the newest message that has a usable one")
    func newestUsableMessageWins() {
        let messages = [
            message("old", hoursAgo: 200, unsubscribe: Self.metadata("<https://old.example/u>")),
            message("new", hoursAgo: 1, unsubscribe: Self.metadata("<https://new.example/u>")),
            message("middle", hoursAgo: 50, unsubscribe: Self.metadata("<https://middle.example/u>")),
        ]

        let result = opportunity(messages)

        #expect(result.mechanism?.destinationHost == "new.example")
        #expect(result.sourceMessageID == MailMessageID("new"))
    }

    @Test("A newest message whose header is unusable does not veto an older usable one")
    func unusableNewestFallsBackToUsableOlder() {
        let messages = [
            message("new", hoursAgo: 1, unsubscribe: Self.metadata("<http://broken.example/u>")),
            message("old", hoursAgo: 48, unsubscribe: Self.metadata("<https://works.example/u>")),
        ]

        let result = opportunity(messages)

        #expect(result.mechanism?.destinationHost == "works.example")
        #expect(result.sourceMessageID == MailMessageID("old"))
        // And the refusal is still reported, because it is still true of this sender's mail.
        #expect(result.evidence.contains(.unusableValue(.insecureScheme)))
    }

    @Test("Disagreement between a sender's own messages costs a band of confidence and is said")
    func varyingMetadataLowersConfidence() {
        let messages = [
            message("m1", hoursAgo: 1, unsubscribe: Self.metadata("<https://a.example/u>")),
            message("m2", hoursAgo: 24, unsubscribe: Self.metadata("<https://b.example/u>")),
        ]

        let result = opportunity(messages)

        #expect(result.confidence == .low)
        #expect(result.evidence.contains(.metadataVariesAcrossMessages(distinctValues: 2)))
        #expect(result.cautionaryEvidence.contains(.metadataVariesAcrossMessages(distinctValues: 2)))
        // A one-click sender whose messages disagree drops to moderate rather than staying at
        // the top band: the endpoint on offer is one of several this sender has used.
        let oneClickVarying = opportunity([
            message("m1", hoursAgo: 1, unsubscribe: Self.metadata("<https://a.example/u>", post: "List-Unsubscribe=One-Click")),
            message("m2", hoursAgo: 24, unsubscribe: Self.metadata("<https://b.example/u>", post: "List-Unsubscribe=One-Click")),
        ])
        #expect(oneClickVarying.confidence == .moderate)
    }

    @Test("Contradictory one-click metadata is surfaced as its own evidence")
    func contradictoryMetadataIsSurfaced() {
        let result = opportunity([
            message("m1", unsubscribe: Self.metadata("<mailto:leave@lists.example>", post: "List-Unsubscribe=One-Click")),
        ])

        #expect(result.evidence.contains(.oneClickDeclaredWithoutURL))
        #expect(result.mechanism?.kind == .mail)
        #expect(result.confidence == .moderate)
    }

    // MARK: - Mechanism selection

    @Test("Selection prefers one-click, then web, then mail, and shows what it did not pick")
    func selectionOrder() {
        let metadata = Self.metadata(
            "<mailto:leave@lists.example>, <https://lists.example/u/abc>",
            post: "List-Unsubscribe=One-Click"
        )
        let selection = UnsubscribeMechanismSelection.select(from: metadata)

        #expect(selection?.chosen.kind == .oneClick)
        #expect(selection?.alternatives.map(\.kind) == [.webPage, .mail])
        #expect(selection?.hasAlternatives == true)
        #expect(selection?.selectionRationale?.contains("one-click unsubscribe standard") == true)
    }

    @Test("Without one-click, the first HTTPS value in header order wins")
    func selectionBreaksTiesByHeaderOrder() {
        let selection = UnsubscribeMechanismSelection.select(
            from: Self.metadata("<https://second.example/u>, <https://first.example/u>")
        )

        // "First" here means first *in the header*, not alphabetically and not by any judgement
        // about which host looks more official.
        #expect(selection?.chosen.webURL?.host == "second.example")
        #expect(selection?.alternatives.first?.webURL?.host == "first.example")
    }

    @Test("The one-click URL also appears as a plain web page, so the user can choose to look")
    func oneClickURLIsAlsoOfferedAsAPage() {
        let selection = UnsubscribeMechanismSelection.select(
            from: Self.metadata("<https://lists.example/u/abc>", post: "List-Unsubscribe=One-Click")
        )

        #expect(selection?.chosen.kind == .oneClick)
        #expect(selection?.alternatives.map(\.kind) == [.webPage])
        #expect(selection?.alternatives.first?.webURL?.host == "lists.example")
    }

    @Test("Selection is deterministic: the same metadata always chooses the same destination")
    func selectionIsDeterministic() {
        let metadata = Self.metadata(
            "<https://a.example/u>, <mailto:x@a.example>, <https://b.example/u>, <mailto:y@b.example>"
        )

        let chosen = (1...25).map { _ in
            UnsubscribeMechanismSelection.select(from: metadata)?.chosen.destinationDescription
        }

        #expect(Set(chosen).count == 1)
        #expect(chosen[0] == "https://a.example/u")
    }

    @Test("Nothing actionable means no selection at all, rather than an empty one")
    func noSelectionWithoutAnActionableTarget() {
        #expect(UnsubscribeMechanismSelection.select(from: Self.metadata("<http://lists.example/u>")) == nil)
        #expect(UnsubscribeMechanismSelection.select(from: .absent) == nil)
        #expect(UnsubscribeMechanismSelection.select(from: .headerPresentUnparsed) == nil)
    }

    // MARK: - Protection

    @Test("A protected sender still shows its mechanism, with a caution rather than a block")
    func protectionChangesToneNotAvailability() {
        let protection = SenderProtectionAssessment(
            level: .protected,
            signals: [ProtectionSignal(kind: .subjectTopic(.financial), confidence: .clear, messageCount: 3)]
        )
        let result = opportunity(
            [message("m1", unsubscribe: Self.metadata("<https://bank.example/u>", post: "List-Unsubscribe=One-Click"))],
            protection: protection
        )

        // The mechanism is not hidden: a user is entitled to turn off their own bank's marketing
        // mail through the app that found it.
        #expect(result.isActionable)
        #expect(result.mechanism?.kind == .oneClick)
        #expect(result.confidence == .standardsDefined)

        // What changes is what is said beside it.
        #expect(result.needsCaution)
        #expect(result.cautionNote?.contains("something you may need") == true)
        #expect(result.cautionNote?.contains("not recommending") == true)
    }

    @Test("An unprotected sender gets no caution note at all")
    func unprotectedSenderHasNoCaution() {
        let result = opportunity([message("m1", unsubscribe: Self.metadata("<https://lists.example/u>"))])

        #expect(!result.needsCaution)
        #expect(result.cautionNote == nil)
    }

    // MARK: - Wording

    @Test("Nothing in the unsubscribe vocabulary claims the user was unsubscribed")
    func noWordingClaimsCompletion() {
        // The sentence this whole interval is organised around. Every headline the app can show
        // for an unsubscribe, checked in one place.
        let outcomes: [UnsubscribeOutcome] = [
            .requestAccepted(host: "lists.example", statusCode: 200),
            .requestSent(host: "lists.example", statusCode: 302),
            .requestFailed(.rejectedByEndpoint(host: "lists.example", statusCode: 410)),
            .browserOpened(host: "lists.example"),
            .mailClientOpened(domain: "lists.example"),
            .handoffFailed(.couldNotOpen),
            .unsupportedMechanism,
            .invalidMetadata,
        ]

        let forbidden = [
            "you are unsubscribed", "you're unsubscribed", "you have been unsubscribed",
            "unsubscribed successfully", "successfully unsubscribed", "removed from the list",
            "you will stop", "no more mail",
        ]

        // A headline is one short line with no room to qualify anything, so these phrases are
        // banned from it outright.
        for outcome in outcomes {
            let headline = outcome.headline.lowercased()
            for phrase in forbidden {
                #expect(!headline.contains(phrase), "\(outcome.kind) headline claims too much: \(phrase)")
            }
        }

        // An explanation may *deny* one of them: "it is not confirmation that you have been
        // removed from the list" is exactly the sentence this feature should be saying, so the
        // rule there is about the claim rather than the words: a sentence containing one of
        // these phrases must be negating it. Checked sentence by sentence, so a denial early in
        // a paragraph cannot license a claim later in it.
        for outcome in outcomes {
            for sentence in outcome.explanation.lowercased().split(separator: ".") {
                for phrase in forbidden where sentence.contains(phrase) {
                    let isDenial = sentence.contains("not ") || sentence.contains("n't ") || sentence.contains("didn't")
                    #expect(isDenial, "\(outcome.kind) asserts \"\(phrase)\" in: \(sentence)")
                }
            }
        }

        // And the two that did reach somebody say "sent", which is the whole point.
        #expect(UnsubscribeOutcome.requestAccepted(host: "lists.example", statusCode: 200).headline == "Unsubscribe request sent")
        #expect(UnsubscribeOutcome.requestSent(host: "lists.example", statusCode: 302).headline == "Unsubscribe request sent")
    }

    @Test("Every Activity headline names an action InboxSweep took, not a result it cannot see")
    func activityHeadlinesNameActions() {
        func entry(_ outcome: UnsubscribeOutcome.Kind, _ mechanism: UnsubscribeMechanism.Kind) -> UnsubscribeActivityEntry {
            UnsubscribeActivityEntry(
                record: UnsubscribeActionRecord(
                    id: UUID(),
                    accountAddress: "someone@example.com",
                    mechanism: mechanism,
                    outcome: outcome,
                    destinationHost: "lists.example",
                    occurredAt: Self.now
                )
            )
        }

        #expect(entry(.requestAccepted, .oneClick).title == "Unsubscribe request sent")
        #expect(entry(.requestSent, .oneClick).title == "Unsubscribe request sent")
        #expect(entry(.browserOpened, .webPage).title == "Opened unsubscribe page")
        #expect(entry(.mailClientOpened, .mail).title == "Opened email unsubscribe request")

        // The caveat rides along with anything that reached somebody.
        #expect(entry(.requestAccepted, .oneClick).explanation.contains("not something InboxSweep can see"))
        #expect(entry(.browserOpened, .webPage).explanation.contains("No message in your mailbox was changed"))
    }

    @Test("The distinction from archiving is stated in one place and says both halves")
    func futureMailNoteSaysBothHalves() {
        let note = UnsubscribeOpportunity.futureMailNote

        #expect(note.contains("Archiving changes messages you already have"))
        #expect(note.contains("messages you haven't received yet"))
        #expect(note.contains("can't undo it"))
        // Every screen that makes the promise makes it in the same words.
        #expect(UnsubscribeReviewSnapshot.futureMailNote == note)
    }

    @Test("There is no undo to offer, and the record says so rather than being silent about it")
    func unsubscribesAreNeverUndoable() {
        let record = UnsubscribeActionRecord(
            id: UUID(),
            accountAddress: "someone@example.com",
            mechanism: .oneClick,
            outcome: .requestAccepted,
            destinationHost: "lists.example",
            occurredAt: Self.now
        )

        #expect(!record.isUndoable)
        #expect(UnsubscribeActivityEntry.noUndoNote.contains("no standard reverse"))

        // And the record has nowhere to put an undo state, which is the structural half.
        let properties = Set(Mirror(reflecting: record).children.compactMap(\.label))
        #expect(properties.isDisjoint(with: ["undoState", "isUndone", "inverse", "reversal"]))
    }
}

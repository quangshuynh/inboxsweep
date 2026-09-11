import Foundation
import Testing
@testable import InboxSweep

/// What a stored transaction *means* once it is a row in the Activity history, and what the
/// retention policy is allowed to throw away.
///
/// Separate from `MutationTransactionStoreTests`, which is about the file. These are about the
/// two properties the screen depends on and the file cannot enforce: that history describes the
/// operation that ran rather than the mailbox as it is now, and that pruning is a rule rather
/// than a coincidence of insertion order.
@Suite("Mutation history")
struct MutationHistoryTests {

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func account(_ address: String = "sample.user@example.com") -> MailAccount {
        MailAccount(emailAddress: EmailAddressParser.parse(address), providerDisplayName: "Gmail")
    }

    private func transaction(
        _ id: UUID = UUID(),
        operation: MailMutationOperation = .archive,
        messageIDs: [String] = ["m-1"],
        selectedCount: Int? = nil,
        confirmedCount: Int? = nil,
        account address: String = "sample.user@example.com",
        secondsAfterEpoch: TimeInterval = 0,
        undoState: MailMutationTransaction.UndoState = .undoable
    ) -> MailMutationTransaction {
        MailMutationTransaction(
            id: id,
            operation: operation,
            accountAddress: address,
            succeededMessageIDs: messageIDs.map { MailMessageID($0) },
            selectedMessageCount: selectedCount ?? confirmedCount ?? messageIDs.count,
            occurredAt: Self.epoch.addingTimeInterval(secondsAfterEpoch),
            undoState: undoState,
            confirmedMessageCount: confirmedCount
        )
    }

    // MARK: - What a record says about the operation that ran

    @Test("A complete archive reads as complete")
    func completeArchive() {
        let archive = transaction(messageIDs: ["m-1", "m-2", "m-3"])

        #expect(archive.outcome == .confirmed)
        #expect(!archive.isPartial)
        #expect(archive.confirmedMessageCount == 3)
        #expect(archive.failedMessageCount == 0)
        #expect(archive.activityStatus == .undoAvailable)
        #expect(ActivityEntry(transaction: archive).title == "Archived 3 messages")
    }

    @Test("A partial archive reads as partial, and names both numbers")
    func partialArchive() {
        // Eight confirmed out of ten selected. The screen has to say both, because "archived 8
        // messages" would quietly drop the two that are still sitting in somebody's inbox.
        let archive = transaction(messageIDs: (1...8).map { "m-\($0)" }, selectedCount: 10)
        let entry = ActivityEntry(transaction: archive)

        #expect(archive.outcome == .partiallyConfirmed)
        #expect(archive.isPartial)
        #expect(archive.failedMessageCount == 2)
        #expect(entry.title == "Archived 8 of 10 messages")
        #expect(entry.unchangedSummary == "2 messages couldn't be archived")
    }

    @Test("An archive that confirmed nothing never claims the mailbox changed")
    func failedArchive() {
        let archive = transaction(messageIDs: [], selectedCount: 4, undoState: .notUndoable)
        let entry = ActivityEntry(transaction: archive)

        #expect(archive.outcome == .failed)
        #expect(!archive.isUndoable)
        #expect(archive.activityStatus == .nothingChanged)
        #expect(entry.title == "No messages were archived")
        #expect(entry.explanation.contains("none of them changed"))
        #expect(!entry.explanation.contains("removed"))
    }

    @Test("A completed undo leaves the archive historically complete")
    func completedUndo() {
        // The case the whole `confirmedMessageCount` field exists for. Three archived, three put
        // back: the archive still archived three, and a screen that recounted the now-empty
        // identifier list would report it as an archive that failed.
        let archive = transaction(messageIDs: [], selectedCount: 3, confirmedCount: 3, undoState: .undone)

        #expect(archive.outcome == .confirmed, "A fully undone archive was rewritten as a failure")
        #expect(archive.confirmedMessageCount == 3)
        #expect(archive.restoredMessageCount == 3)
        #expect(archive.activityStatus == .undoCompleted)
        #expect(ActivityEntry(transaction: archive).title == "Archived 3 messages")
    }

    @Test("A partial undo leaves the archive historically complete, and says what came back")
    func partialUndo() {
        // Ten archived, four put back, six still archived and still undoable.
        let archive = transaction(
            messageIDs: (1...6).map { "m-\($0)" },
            selectedCount: 10,
            confirmedCount: 10,
            undoState: .undoable
        )
        let entry = ActivityEntry(transaction: archive, isUndoable: true)

        #expect(archive.outcome == .confirmed, "A partial undo was read as a partial archive")
        #expect(archive.isPartiallyUndone)
        #expect(archive.restoredMessageCount == 4)
        #expect(archive.succeededCount == 6, "The remaining undo offer should name only what is still archived")
        #expect(archive.activityStatus == .undoPartiallyCompleted)
        #expect(entry.title == "Archived 10 messages")
        #expect(entry.statusSummary == "Partly undone — 4 of 10 put back, 6 still archived")
    }

    @Test("Narrowing an undo offer changes the offer and not the history")
    func narrowingKeepsHistory() throws {
        let archive = transaction(messageIDs: (1...10).map { "m-\($0)" }, selectedCount: 12)
        let narrowed = archive.narrowingUndoOffer(to: (5...10).map { MailMessageID("m-\($0)") })

        #expect(narrowed.id == archive.id)
        #expect(narrowed.occurredAt == archive.occurredAt)
        #expect(narrowed.selectedMessageCount == 12)
        #expect(narrowed.confirmedMessageCount == 10, "Narrowing rewrote what the archive confirmed")
        #expect(narrowed.succeededCount == 6)
        #expect(narrowed.outcome == .partiallyConfirmed, "The archive was partial then and is partial now")
        #expect(narrowed.undoState == .undoable)

        // Narrowing to nothing is a completed undo, not a failed archive.
        let emptied = archive.narrowingUndoOffer(to: [])
        #expect(emptied.undoState == .undone)
        #expect(emptied.confirmedMessageCount == 10)
        #expect(emptied.activityStatus == .undoCompleted)
    }

    @Test("A superseded archive keeps saying what it did")
    func supersededArchive() {
        let archive = transaction(messageIDs: ["m-1", "m-2"], undoState: .superseded)
        let entry = ActivityEntry(transaction: archive)

        #expect(!archive.isUndoable)
        #expect(archive.activityStatus == .undoSuperseded)
        #expect(entry.title == "Archived 2 messages")
        #expect(entry.statusSummary == "Undo superseded by a later archive")
        #expect(entry.explanation.contains("A later archive replaced this one"))
    }

    @Test("A restore is recorded as its own change, and is never itself undoable")
    func restoreEntry() {
        let restore = transaction(
            operation: .restoreToInbox,
            messageIDs: ["m-1", "m-2", "m-3"],
            undoState: .notUndoable
        )
        let entry = ActivityEntry(transaction: restore)

        #expect(restore.activityStatus == .restore)
        #expect(!restore.isUndoable)
        #expect(entry.title == "Put 3 messages back in your Inbox")
        #expect(entry.statusSummary == nil)
    }

    @Test("A failed undo is its own record, and does not unsay the archive")
    func failedUndoIsRecordedSeparately() {
        // An undo Gmail refused entirely. The archive it was trying to reverse is untouched by
        // it — which is the property that stops a failed undo from being reported as though the
        // mail had never been archived.
        let archive = transaction(messageIDs: ["m-1", "m-2"], undoState: .undoable)
        let failedUndo = transaction(
            operation: .restoreToInbox,
            messageIDs: [],
            selectedCount: 2,
            undoState: .notUndoable
        )

        #expect(archive.outcome == .confirmed)
        #expect(archive.isUndoable, "A failed undo withdrew the offer")
        #expect(failedUndo.outcome == .failed)
        #expect(ActivityEntry(transaction: failedUndo).title == "No messages were put back")
    }

    // MARK: - Nothing here describes the mail

    @Test("A history row is descriptive with no message metadata at all")
    func rowsNeedNoMailboxMetadata() {
        // The privacy claim, as a test. An entry built with an empty cache still produces a
        // headline, a status, and an explanation — which is why the record does not need to keep
        // subjects or senders to stay useful.
        let entry = ActivityEntry(transaction: transaction(messageIDs: ["m-1", "m-2", "m-3"]))

        #expect(!entry.hasResolvedMetadata)
        #expect(entry.title == "Archived 3 messages")
        #expect(entry.statusSummary == "Undo available")
        #expect(!entry.explanation.isEmpty)

        // …and it says why the details are missing, rather than looking like data loss.
        let fallback = entry.metadataFallback ?? ""
        #expect(fallback.contains("records what it changed, not the mail itself"))
    }

    @Test("Resolved metadata decorates a row and is never required by it")
    func resolvedMetadataIsOptional() {
        let messages = ProposalFixtures.promotionalSender(count: 3)
        let archive = transaction(messageIDs: messages.map(\.id.rawValue))

        let withCache = ActivityEntry(transaction: archive, resolvedMessages: messages)
        let withoutCache = ActivityEntry(transaction: archive)

        // The facts are identical either way. Only the decoration differs.
        #expect(withCache.title == withoutCache.title)
        #expect(withCache.confirmedCount == withoutCache.confirmedCount)
        #expect(withCache.statusSummary == withoutCache.statusSummary)
        #expect(withCache.hasResolvedMetadata)
        #expect(withCache.metadataFallback == nil)
        #expect(withoutCache.metadataFallback != nil)
    }

    @Test("A partly-resolvable row says how much of it the cache still covers")
    func partiallyResolvedMetadata() {
        let messages = ProposalFixtures.promotionalSender(count: 5)
        let archive = transaction(messageIDs: messages.map(\.id.rawValue))
        let entry = ActivityEntry(transaction: archive, resolvedMessages: Array(messages.prefix(2)))

        #expect(entry.hasResolvedMetadata)
        #expect(entry.metadataFallback?.contains("2 of 5") == true)
    }

    @Test("No wording anywhere celebrates, or calls archiving deletion")
    func wordingStaysFactual() {
        let cases = [
            transaction(messageIDs: ["m-1", "m-2"]),
            transaction(messageIDs: (1...8).map { "m-\($0)" }, selectedCount: 10),
            transaction(messageIDs: [], selectedCount: 3, undoState: .notUndoable),
            transaction(messageIDs: [], selectedCount: 3, confirmedCount: 3, undoState: .undone),
            transaction(messageIDs: ["m-9"], selectedCount: 4, confirmedCount: 4, undoState: .superseded),
            transaction(operation: .restoreToInbox, messageIDs: ["m-1"], undoState: .notUndoable),
        ]
        // Phrases that would be *false* or self-congratulatory, not the word "delete" itself —
        // the wording has to be free to say that archiving is not deleting, and does.
        let forbidden = [
            "was deleted", "were deleted", "permanently removed", "removed forever",
            "gone for good", "inbox cleaned", "cleaned up", "useless", "junk",
            "spam eliminated", "great job", "nice work", "well done", "🎉", "✨",
        ]

        for transaction in cases {
            let entry = ActivityEntry(transaction: transaction)
            let text = [entry.title, entry.statusSummary ?? "", entry.unchangedSummary ?? "", entry.explanation]
                .joined(separator: " ")
                .lowercased()

            for phrase in forbidden {
                #expect(!text.contains(phrase), "Activity wording used \"\(phrase)\": \(text)")
            }
        }

        // And the one claim it is important to keep making.
        let archived = ActivityEntry(transaction: cases[0])
        #expect(archived.explanation.contains("does not delete"))
    }

    // MARK: - Retention

    @Test("A history below the limit is kept whole, newest first")
    func belowLimit() {
        let transactions = (0..<10).map {
            transaction(messageIDs: ["m-\($0)"], secondsAfterEpoch: Double($0))
        }

        let pruned = MailMutationHistory.pruned(transactions.shuffled())
        #expect(pruned.count == 10)
        #expect(pruned.map(\.occurredAt) == pruned.map(\.occurredAt).sorted(by: >))
        #expect(pruned.first?.messageID == MailMessageID("m-9"))
    }

    @Test("A history exactly at the limit loses nothing")
    func exactlyAtLimit() {
        let limit = MailMutationHistory.entryLimit
        let transactions = (0..<limit).map {
            transaction(messageIDs: ["m-\($0)"], secondsAfterEpoch: Double($0), undoState: .superseded)
        }

        #expect(MailMutationHistory.pruned(transactions).count == limit)
    }

    @Test("A history above the limit keeps the newest and drops the oldest")
    func aboveLimit() {
        let limit = MailMutationHistory.entryLimit
        let transactions = (0..<(limit + 25)).map {
            transaction(messageIDs: ["m-\($0)"], secondsAfterEpoch: Double($0), undoState: .superseded)
        }

        let pruned = MailMutationHistory.pruned(transactions)
        #expect(pruned.count == limit)
        #expect(pruned.first?.messageID == MailMessageID("m-\(limit + 24)"))
        #expect(!pruned.contains { $0.messageID == MailMessageID("m-0") })
    }

    @Test("Pruning is deterministic, whatever order the entries arrive in")
    func pruningIsDeterministic() {
        // Same timestamp on every entry, which is the case a merely-descending sort gets wrong:
        // `sort(by:)` is not stable, so without the identifier tiebreak the same file would
        // produce different histories on different reads.
        let limit = MailMutationHistory.entryLimit
        let transactions = (0..<(limit + 20)).map { _ in
            transaction(messageIDs: ["m-\(UUID().uuidString)"], undoState: .superseded)
        }

        let first = MailMutationHistory.pruned(transactions).map(\.id)
        for _ in 0..<5 {
            #expect(MailMutationHistory.pruned(transactions.shuffled()).map(\.id) == first)
        }
    }

    @Test("Pruning an already-pruned history changes nothing")
    func pruningIsIdempotent() {
        let transactions = (0..<(MailMutationHistory.entryLimit + 5)).map {
            transaction(messageIDs: ["m-\($0)"], secondsAfterEpoch: Double($0), undoState: .superseded)
        }

        let once = MailMutationHistory.pruned(transactions)
        #expect(MailMutationHistory.pruned(once) == once)
    }

    @Test("The transaction an undo is still offered for is never pruned")
    func currentUndoSurvivesPruning() throws {
        // The one entry whose loss would be a change in what the app can *do*, rather than in
        // what it can show. It is deliberately the oldest here, which is the case a plain
        // newest-first prefix gets wrong.
        let undoable = transaction(messageIDs: ["still-archived"], secondsAfterEpoch: 0, undoState: .undoable)
        let newer = (1...(MailMutationHistory.entryLimit + 10)).map {
            transaction(messageIDs: ["m-\($0)"], secondsAfterEpoch: Double($0), undoState: .superseded)
        }

        let pruned = MailMutationHistory.pruned(newer + [undoable])
        #expect(pruned.count == MailMutationHistory.entryLimit)
        #expect(
            pruned.contains { $0.id == undoable.id },
            "Pruning withdrew an undo offer the user could still see"
        )
    }

    @Test("One account's history never displaces or reaches another's")
    func retentionIsPerAccount() {
        // A file whose header and entries disagree about whose mailbox they describe is the only
        // way this can happen, and it is exactly the kind of file the reader must not trust.
        let mine = (0..<5).map {
            transaction(messageIDs: ["mine-\($0)"], account: "first@example.com", secondsAfterEpoch: Double($0))
        }
        let theirs = (0..<(MailMutationHistory.entryLimit + 50)).map {
            transaction(
                messageIDs: ["theirs-\($0)"],
                account: "second@example.net",
                secondsAfterEpoch: Double(1_000 + $0)
            )
        }

        let history = MailMutationHistory.history(mine + theirs, for: account("first@example.com"))
        #expect(history.count == 5, "Another account's entries crowded out this one's")
        #expect(history.allSatisfy { $0.accountAddress == "first@example.com" })
        #expect(!history.contains { $0.succeededMessageIDs.contains(MailMessageID("theirs-0")) })

        #expect(MailMutationHistory.history(mine + theirs, for: account("nobody@example.org")).isEmpty)
    }
}

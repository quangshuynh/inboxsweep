# Activity

The local answer to one question: **what has InboxSweep changed in my mailbox?**

Activity is a reader. Opening it, scrolling it, and opening a row send nothing to Gmail. The one
control on it that can reach a mailbox is **Undo**, and that is the existing undo — the same
offer the message review screen makes, for the same single transaction, through the same code
path. No row can archive anything.

---

## What Activity records

Every operation InboxSweep itself attempted, with what the provider confirmed:

| Recorded | Meaning |
| --- | --- |
| A stable transaction identifier | One confirmation is one entry, however many times its button was pressed |
| The account it was performed for | Checked before an entry is shown *and* before an undo is sent |
| The operation | `archive` or `restoreToInbox` — there are no others |
| When it finished | The timestamp shown on the row |
| How many messages were selected | What you confirmed, including the ones that failed |
| How many were confirmed | What Gmail actually changed, fixed at the moment it answered |
| The messages still undoable | Provider identifiers, and only for messages still out of the Inbox |
| Its undo state | Whether an undo stands, was superseded, or has been carried out |

## What Activity does not record

**No mail.** No message bodies, no snippets, no attachments, and no raw provider responses —
`MailMessage` has nowhere to hold the first three, and Gmail's responses are normalized at the
adapter boundary and discarded.

Also, deliberately, **no subjects and no sender addresses**. They are not needed for correctness:
an undo acts on identifiers, and every count on the screen comes from numbers. Copying them into
the transaction file would put the same mailbox content in a second place purely so that an old
row stayed descriptive, and a row that says

> Archived 3 messages

is worth more than three subjects kept on disk forever. Privacy wins over historical decoration.

### Where the subjects on a row come from, then

The local mailbox cache. When the loaded window still contains the messages a transaction named,
the detail view resolves their subjects and dates *dynamically* and shows them. When it does not
— an archive from three months ago, a window that has since been reloaded, a different scope —
the row says so and shows the counts, which were never dependent on the cache in the first place.

**History never depends on cache availability.** Losing the metadata costs you subjects, not
facts.

## Transaction states

| State | What it means |
| --- | --- |
| **Undo available** | An archive whose messages InboxSweep can still put back |
| **Undo superseded** | A later archive replaced it as the account's undo offer. Its messages are still archived; there is no standing offer to reverse it |
| **Undone** | Every message this archive confirmed has been put back |
| **Partly undone** | Some of its messages have been put back and some have not |
| **Nothing changed** | Gmail confirmed nothing. No undo, because nothing happened |
| *(a restore)* | The record of an undo. Not itself undoable — its inverse is archiving, which you ask for explicitly |

There is deliberately **no state meaning "this message is in your mailbox now"**. A transaction
is a record of an operation, not a claim about where your mail is today; you may well have moved
it since.

### Partial operations stay partial

An archive of 10 that confirmed 8 reads *"Archived 8 of 10 messages"* forever. An undo of 4 out
of 10 reads *"Partly undone — 4 of 10 put back"* forever. Neither is rounded up later.

This is less obvious than it sounds. A partial undo has to *narrow* the transaction's identifier
list, so a second undo asks Gmail only about messages that are still archived — and that narrowing
would otherwise rewrite the history underneath it. Archive ten, put four back, and a screen
counting the remaining six would report *"Archived 6 of 10"*: a partial archive that never
happened. `confirmedMessageCount` is the historical fact, fixed when the provider answered, and
every count on the screen derives from it.

### Undo and supersession

**At most one transaction per account is ever undoable.** A new archive that confirms anything
supersedes the previous offer; the superseded transaction stays in the history, because it is
still a true record of what the app did.

Activity does not change that rule, and being visible does not make an entry actionable. An
older or superseded row shows its state and offers no button. Undo appears only on the single
transaction the session already considers undoable — same account, still `undoable`, archive
permission still granted — and uses the identifiers that transaction confirmed rather than
anything reconstructed from what is on screen.

## Activity is not Gmail's history

> **Activity is what InboxSweep changed. It is not everything that happened in Gmail.**

If you archive or restore a message in Gmail itself — the web app, your phone, a filter — the
next reload reconciles InboxSweep's view of your mailbox, and **no Activity entry is written**.
The app did not do it, and a list of changes that quietly claimed credit for other people's work
would be worse than no list at all.

So a message can be absent from your Inbox without appearing here, and that is correct.

## Retention

**The 100 most recent entries per account**, on this Mac.

Why 100:

- InboxSweep writes one entry per deliberate action. There is no automation, no schedule, and
  nothing in the background that could write one — so 100 entries is on the order of a year of
  ordinary use.
- An archive and its undo are two entries, so the useful depth is nearer fifty operations. That
  is the number the limit was chosen against.
- The whole file is read, validated, and rewritten on every mutation. At 100 entries that is a
  few kilobytes of identifiers; at ten thousand it would eventually be a visible pause at exactly
  the wrong moment.
- It bounds the worst case: 100 × 5,000 identifiers is the absolute ceiling on what the app will
  ever hold for one account.

Pruning happens when the file is written and again when it is read, so a file that somehow grew
is still bounded in memory. There is **no time-based cleanup and nothing running in the
background** — a retention policy that expired entries by age would need something to run, and
nothing in InboxSweep runs on its own.

Two guarantees on top of the limit:

- **Deterministic.** Entries are ordered newest first and ties are broken by identifier, so the
  same file always produces the same history. Without the tiebreak, two entries written in the
  same second would prune differently depending on which the file happened to list first.
- **A live undo is never pruned.** An entry the app would still offer an undo for is kept
  whatever its age. Losing it is not a cosmetic loss: the mail stays archived and the app quietly
  stops being able to put it back.

Malformed and unrecognised entries are dropped rather than guessed at, and one account's history
can never crowd out or reach another's.

## Accounts, and what disconnecting does

**Signing out deletes this account's Activity**, along with its cached mailbox window and its
saved preview choices. This is unchanged from the interval that introduced the transaction file,
and it remains the right behaviour: disconnecting is you saying you are done, and a list of what
was done to a mailbox the app can no longer even look at is not worth keeping on your behalf.

Nothing is retained after a disconnect, so there is no question of it becoming visible later
under a different account.

Account isolation holds in three independent places:

- one file per account, named by a digest of the address, so the address is not legible from a
  directory listing;
- every other account's file is removed when one is written, so at most one account's history is
  ever on disk;
- entries are filtered by account before anything is shown, so a file whose header and entries
  disagreed could not produce a row for the wrong mailbox.

## Empty and edge states

| State | What you see |
| --- | --- |
| Nothing archived yet | "No activity yet", and what will appear here when you archive something |
| History, but no current undo | Rows with their states; no Undo button |
| Current undo available | Undo on that one row, naming how many messages it would put back |
| Partial archive | "Archived 8 of 10 messages", and how many could not be archived |
| Partial undo | "Partly undone — 4 of 10 put back, 6 still archived" |
| Cache metadata unavailable | Counts as normal, and a line saying InboxSweep records what it changed rather than the mail |
| Account switched | The new account's history, or its empty state |
| Malformed entry | Dropped silently; the rest of the history is shown |
| Pruned by retention | The footer states the limit, so an old change disappearing is expected rather than alarming |

The wording throughout is factual. There is no "Inbox cleaned!", no "spam eliminated", and no
count of "useless emails removed" — archiving is not deletion, and InboxSweep's proposals are
heuristics rather than certainty.

## Safety

This interval added **zero** new remote capability:

- no new OAuth scope — still `gmail.metadata` and `gmail.modify`;
- no new Gmail endpoint — still the two `messages/{id}/modify` calls;
- `MailMessageArchiving` gained no method;
- opening Activity, opening a row, loading the history, pruning it, and resolving cached
  metadata all perform **zero** provider writes, asserted in `ActivityHistoryTests`;
- the only way to write from Activity is the already-existing explicit Undo.

## A note on the UI tests

Two UI cases are red, and one covers less than it should. Both are environmental rather than
defects in the app, and both are written up in `InboxSweepUITests.swift`:

- **Occlusion.** XCUITest cannot compute a hit point for a control when another application's
  window covers it. Every case that only asserts passes; every case that clicks in-content fails
  when the desktop is busy. `UITestWindow` pins the window's size and position so the geometry is
  the test's rather than the desktop's, which removes the half of the problem that is
  controllable.
- **Toolbar buttons.** XCUITest cannot click a SwiftUI toolbar button in this app at all — with
  every other window hidden, the runner reported no interrupting elements, clicked, and the app
  did not react. This predates Activity; `dashboard.disconnectButton` behaves identically. So the
  Activity case asserts its entry point, and the screen behind it is covered by
  `MutationHistoryTests`, `ActivityHistoryTests`, and manual verification.

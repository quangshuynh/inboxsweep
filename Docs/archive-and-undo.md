# Archiving and undo

Archiving is InboxSweep's primary write, and the only one that can be undone.

!!! warning "Archiving is not deleting"

    In Gmail a message is in your Inbox exactly when it carries the `INBOX` label, so archiving
    one *is* removing that label. The message stays in All Mail, stays in search, keeps every
    other label, and keeps its read state, star, importance marker, and Gmail category.

## The two requests

```
POST https://gmail.googleapis.com/gmail/v1/users/me/messages/{id}/modify
{"removeLabelIds":["INBOX"]}
```

Undo is the same call with the label added back:

```
POST https://gmail.googleapis.com/gmail/v1/users/me/messages/{id}/modify
{"addLabelIds":["INBOX"]}
```

Those two are the **complete** set of mutating requests the app can construct. The body is not a
parameter: `GmailMutationRequest.InboxLabelChange` holds two literal constants, so "add or remove
`INBOX` on one named message" is the app's entire mutation vocabulary rather than a convention
someone has to maintain.

| Archiving does | Archiving does not |
| --- | --- |
| Remove `INBOX` from each message you confirmed | Delete any message |
| Leave them in All Mail, in search, and under every other label | Move anything to Trash |
| Leave read state, stars, importance, and categories untouched | Mark anything read or unread |
| Act on the messages you ticked, one at a time | Act on their threads, their sender, or anything else |

### Message-level, not thread-level

Gmail also offers `users.threads.modify`, which archives every message in a conversation.
InboxSweep does not use it. You picked specific messages; archiving the others in their threads
would be doing more than you asked. A conversation whose other messages are still in your Inbox
therefore stays in your Inbox, which is Gmail's own behaviour, and is what the confirmation says.

### One request per message, and not `batchModify`

Gmail publishes `users.messages.batchModify`, which would apply one label change to up to a
thousand messages in a single request. InboxSweep does not use it, and performance was not the
deciding question.

- `batchModify` answers `204 No Content`. It reports no per-message result and does not echo the
  messages back, so there would be nothing to reconcile local state *against*. The app would be
  reduced to assuming the change it asked for is the change that happened, which is the
  assumption every other write here refuses to make.
- A partial failure inside a batch is not expressible in its reply. "Eight of your twelve were
  archived" could not be said, and saying it is the point of the whole feature.
- One request naming a thousand identifiers is a larger blast radius per mistake than one request
  naming one.

So a set of twelve is twelve `messages.modify` calls, sent **strictly one at a time**, never in
parallel. Sequential costs latency on large sets and buys honest cancellation and a bounded
footprint on your Gmail quota. A safety test asserts two requests are never in flight at once.

## Where a selection comes from

Three controls fill in a selection, and **none of them is an action**. Each writes ticks into a
checkbox column you then read, edit, and confirm.

| Control | What it ticks |
| --- | --- |
| **Select all shown** | Everything currently listed, minus anything protected |
| **Fill from preview** | The messages the current [dry-run preview](cleanup-proposals.md#dry-run-previews) would reach, minus anything protected |
| **Review messages to archive…** | Opens the review with the preview's messages already ticked. It is not *Archive sender*: it opens a screen and changes nothing |

A selection **cannot cross a sender**. The review is per sender, so there is no way to assemble
one set spanning several of them, and no whole-sender operation behind any of these controls.

!!! note "Preselection is not authorization"

    A sender with four hundred messages of which 250 are loaded gets candidates from the 250, and
    the screen says which window its counts describe. You still inspect the list, edit it in both
    directions, open a confirmation, and press the button. Confirming an archive creates no
    [rule](rules.md): authorizing future behaviour is a separate thing you do deliberately, on
    its own screen.

## Protected messages

No convenience control ever ticks a [protected](cleanup-proposals.md#step-1-protection-runs-first-and-can-only-veto)
message. You can tick one yourself, and the confirmation says so when you have.

## The confirmation

1. Open a sender.
2. Open **Review…**, or **Review messages to archive…** for a preselected list.
3. Tick the messages you want archived.
4. Press **Archive N messages…**.
5. Read the confirmation.
6. Press **Archive N messages**.

The confirmation names the sender, the count, and **every message in the set** by subject and
received date: the whole list, never "and 34 more". A confirmation you cannot read in full is not
a confirmation, so the sheet scrolls instead of summarising. It states plainly that the messages
will be removed from your Inbox and will not be deleted.

### The set is frozen

Between opening a confirmation for twelve messages and pressing the button, a page can land, a
reload can finish, and the list underneath can become a different list. A confirmation wired to
live state would be showing one set while archiving another, and you would have no way to tell.

So the confirmation is wired to an **immutable snapshot** taken when you asked to review the set.
Nothing recomputes it and nothing refreshes it. **The list on screen is the list that gets
archived, or nothing does.**

The snapshot carries the exact message identifiers with the subject, date, and protection reason
each had at review time; the account the window was read for; the sender they belong to; the
mailbox scope that was loaded; and one operation identifier, which is what makes a repeated press
recognisably the same operation rather than a second one.

### What is re-checked immediately before anything is sent

- the authenticated account still matches, asked of the provider rather than read from the
  snapshot, because the question is which account the token authenticates **now**;
- the archive permission is still granted;
- the loaded scope is still the one the set was frozen under;
- every message is still loaded, still in scope, and still belongs to the expected sender;
- every message is still in the Inbox. One archived elsewhere since the review, in Gmail on the
  web or on a phone, would produce a request whose answer you could not tell apart from the one
  you asked for;
- **this confirmation has not already been carried out**, for the life of the session rather than
  only while its result is on screen.

If any of that has changed, the operation is **refused whole and re-reviewed**. It is never
narrowed to the messages that still match, because acting on "the ones still there" would be
acting on a set nobody approved, and never re-derived from fresher planner output, because that
would be executing a set you have not seen.

### While it is running

- The sheet is modal, so the selection cannot change under the confirmation.
- A second submission is refused by the session itself in two ways: nothing runs while something
  is running, **and** a frozen set that has already executed cannot execute again. The second
  guard is the one a disabled button misses.
- **Stop is a real button**, because sequential execution makes it a real promise: it stops
  before the next message. The request already with Gmail cannot be recalled, and the sheet says
  exactly that rather than implying otherwise.
- Nothing on screen changes until Gmail confirms each message. There is no optimistic update, so
  a failure needs no rollback and a success is never claimed early.

## Partial failure

A set does not succeed or fail. Twelve selected with four refused is **eight real changes to your
mailbox**, and reporting that as "archiving failed" would tell you the opposite of what happened
to the other eight.

```
12 selected     8 archived     4 failed
```

| Outcome | Meaning |
| --- | --- |
| **Archived** | Gmail confirmed it. The message has left your Inbox |
| **Failed** | Gmail was asked and refused. The message is unchanged and still in your Inbox |
| **Not sent** | No request was ever made: you stopped the run, or a session-wide failure made the rest pointless. Knowably unchanged |

Each row carries the app's own one-line reason, never Gmail's response body, an authorization
code, or a token.

- **Local state reconciles only the messages Gmail confirmed.** Failures keep the labels they had,
  so local and remote agree and a refresh converges on the same state.
- **Successes are never rolled back** because something else failed. Putting them back would be
  the app rewriting history it does not own, and would be more writes nobody asked for.
- **Failed messages are offered again where that makes sense.** A rate limit or a dropped
  connection is worth retrying; a message Gmail no longer has, or an account that changed, is not.
- **The undo transaction names the successful subset only.**

### When a run stops early

A failure about *this message* (throttling, a dropped connection, a message Gmail no longer has)
says nothing about the next one, so the run continues and each message gets its own answer.

A failure about *the session* (a withdrawn grant, an expired authorization, a swapped account) is
true of every message at once. The run stops rather than sending eleven more requests that will
all be refused identically, and the remainder are reported as **not sent**.

## Undo

Undo is a **real Gmail request per message**, through the same boundary the archive went through,
not a local correction. It restores only the messages that transaction confirmed. Nothing is
inferred into the set: not the rest of the sender, not the rest of a thread, not messages archived
by an earlier operation.

| | |
| --- | --- |
| **Lifetime** | Survives dismissing the sheet, reloading, and quitting the app. There is no timer |
| **How many** | **One undoable archive per account.** A new one supersedes the last |
| **Ends on** | Undo, supersession, or disconnect |
| **Can itself fail** | Yes, partly. It then narrows to what is still archived |
| **History** | Narrowing the offer does not rewrite the record. A superseded transaction stays in the file as history |

An archived message leaves the loaded window without leaving memory: Inbox membership is derived
from labels, which is what lets undo restore a message to its **original position** rather than
appending it, and what makes the next refresh agree.

!!! warning "Only the most recent archive is undoable"

    There is no undo stack. Once an offer is superseded or used, those messages are in All Mail
    and moving them back is a Gmail operation. A [rule-driven archive](rules.md#undo) has no undo
    at all, deliberately, and Activity says so.

## The local record

Every mutation writes one transaction to a bounded local file: the operation, the confirmed
message IDs, the selected count, the account, a timestamp, and the undo state. **No subject, no
sender, no body.** It is what makes undo survive a relaunch, and it is what
[Activity](activity.md) reads.

The reader is strict on purpose: a record it cannot fully understand is discarded rather than
partially trusted, because a half-read transaction is a wrong undo offer.

!!! note "If the mailbox changed but this Mac could not write it down"

    That is reported as a **success with a caveat**. Gmail really did change your mailbox; the
    only thing that failed was the local record, which costs you the undo offer. The opposite
    behaviour, reporting a failure, would tell you your mail was untouched when it was not.

## Account isolation

Every transaction names the account it belongs to. A second account never sees the first one's
undo offer, its history, or its cache. Disconnecting deletes all of it.

## Recommendations still cannot execute

Proposals, dry-run previews, and saved plans are advisory. **Fill from preview** and **Review
messages to archive…** are the only bridges between a recommendation and a change, and both do
nothing but write ticks into a checkbox column. See
[Why proposals are not executable](cleanup-proposals.md#why-proposals-are-not-executable).

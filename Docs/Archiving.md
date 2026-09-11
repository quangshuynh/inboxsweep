# Archiving messages

InboxSweep's only ability to change a mailbox: removing **the messages you tick and then confirm
as a list** from your Inbox, and putting them back.

Everything else in the app still reads, reasons, and describes. The cleanup proposals and the
dry-run planner remain advisory and have no execution path. They can lead you to the screen where
you select messages, and they can *fill in* a selection for you to check, and they stop there.
Nothing in InboxSweep carries out a recommendation.

That includes the sender-level convenience added in Interval 9. **Review messages to archive…**
opens a review with boxes already ticked. It is not an archive of a sender, and there is no
whole-sender operation behind it; see [Sender-level review](#sender-level-review).

---

## What archiving does

In Gmail, a message is in your Inbox exactly when it carries the `INBOX` label. So archiving a
message *is* removing that label, and that is the whole of what InboxSweep does: once per
message, however many you selected:

```
POST https://gmail.googleapis.com/gmail/v1/users/me/messages/{id}/modify
{"removeLabelIds":["INBOX"]}
```

Undo is the same call with the label added back:

```
POST https://gmail.googleapis.com/gmail/v1/users/me/messages/{id}/modify
{"addLabelIds":["INBOX"]}
```

Those two requests are the **complete** set of mutating requests the app can construct. The
body is not a parameter: `GmailMutationRequest.InboxLabelChange` holds two literal constants,
so "add or remove `INBOX` on one named message" is the app's entire mutation vocabulary rather
than a convention someone has to maintain.

| Archiving does | Archiving does not |
| --- | --- |
| Remove `INBOX` from each message you confirmed | Delete any message |
| Leave them in All Mail, in search, and under every other label | Move anything to Trash |
| Leave read state, stars, importance, and Gmail categories untouched | Mark anything read or unread |
| Act on the messages you ticked, one at a time | Act on their threads, their sender, or anything else |

### Message-level, not thread-level

Gmail also offers `users.threads.modify`, which archives every message in a conversation.
InboxSweep does not use it. You picked specific messages in the review list; archiving the others
in their threads would be doing more than you asked. A conversation whose other messages are
still in your Inbox therefore stays in your Inbox, which is Gmail's own behaviour for archiving
a single message, and is what the confirmation says.

### One request per message, and not `batchModify`

Gmail publishes `users.messages.batchModify`, which would apply one label change to up to a
thousand messages in a single request. **InboxSweep does not use it**, and performance was not
the deciding question:

- `batchModify` answers `204 No Content`. It reports no per-message result and does not echo the
  messages back, so there would be nothing to reconcile local state *against*: the app would be
  reduced to assuming the change it asked for is the change that happened, which is the
  assumption every other write in this app refuses to make.
- A partial failure inside a batch is not expressible in its reply. "Eight of your twelve were
  archived" could not be said, and saying it is the point of the whole feature.
- One request naming a thousand identifiers is a larger blast radius per mistake than one request
  naming one.

So a set of twelve is twelve `messages.modify` calls: the exact call archiving has always used,
sent **strictly one at a time**, never in parallel. Sequential costs latency on large sets and
buys two things worth more: honest cancellation, and a bounded footprint on your Gmail quota.
`SafetyBoundaryTests` asserts two requests are never in flight at once.

---

## The Gmail permission

InboxSweep requests two scopes:

| Scope | For |
| --- | --- |
| `https://www.googleapis.com/auth/gmail.metadata` | Reading headers, labels, and dates. Not bodies. |
| `https://www.googleapis.com/auth/gmail.modify` | Changing which labels a message carries. |

### `gmail.modify` is broader than what the app does with it

It has to be said plainly, because Google's consent screen will describe it in its broadest
terms. `gmail.modify` would also permit trashing a message, marking mail read, applying
arbitrary labels, and reading message bodies. **Google publishes no narrower permission that can
archive.** `gmail.labels` governs creating and deleting label *definitions*, not applying them
to a message; `gmail.insert` and `gmail.compose` are about putting mail into a mailbox. The
alternative to `gmail.modify` is not a smaller scope: it is not having an archive feature.

Since the permission cannot be narrowed, the limit lives in the code instead:

- the only mutating requests that exist are the two above, and they take no label parameter;
- every read is still `format=metadata` with four named headers, so message bodies are never
  requested even though the grant would now allow it;
- `SafetyBoundaryTests` fails if a third mutating request builder appears, if one reaches a
  trash, delete, send, settings, batch, or thread path, if a mutation body names any label other
  than `INBOX`, or if any body format is ever requested.

The signed-out screen states all of this before you are sent to Google, rather than describing
the permission as "archiving" and letting the consent screen contradict it.

### What is still never requested

`https://mail.google.com/` (full access, including **permanent deletion**), `gmail.send`,
`gmail.compose`, `gmail.insert`, `gmail.labels`, `gmail.settings.*`, and contacts. Permanent
deletion is the one mailbox change that cannot be undone, and it is the line the app will not
cross.

---

## If you signed in before archiving existed

Your stored grant covers reading and not archiving. That is **not** treated as a broken
credential:

- the grant restores normally, and the whole app works as it did;
- the Archive control is replaced by **Enable archiving…**, which explains what is missing;
- pressing it starts a re-authorization, and nothing else;
- declining leaves the read-only grant exactly as it was, with a notice saying why the button
  stays unavailable;
- granting it persists the widened scope through the existing Keychain credential store,
  including in the usual case where Google issues no new refresh token, where the working
  refresh token is kept and only the scope record is updated.

Granting the permission archives nothing. Consenting and archiving are two separate presses, on
purpose.

A stored grant that no longer covers *reading* is still discarded and still asks you to connect
again, as before.

---

## Selecting the messages

Archiving starts from individual messages in the sender message review: the screen that already
exists for looking at them one by one. No proposal, sender row, dry-run plan, or saved plan can
open a confirmation; only ticking rows and pressing **Archive…** does.

The selection lives in the review screen and nowhere else. It is not stored, not remembered
between openings, and the session never learns about it until you ask for a confirmation, which
is what makes "selecting changes nothing" true by construction rather than by discipline.

### The three bulk controls, and what they cannot do

| Control | What it does | What it does not do |
| --- | --- | --- |
| **Select all shown** | Ticks every message currently listed | Reach messages the filter is hiding |
| **Deselect all** | Clears the selection | Nothing |
| **Fill from preview** | Ticks the messages the selected preview would affect | Archive anything; tick a protected message |
| **Review messages to archive…** | Opens this screen with those messages already ticked | Archive anything; tick a protected message; affect future mail |

**Fill from preview** is the bridge between the dry run and a real change, and it is deliberately
the *only* one. "38 messages would be affected" is useless if you cannot get at the 38, so this
writes them into the checkbox column, and then stops. You still read the list, untick what you
want to keep, tick anything the rules missed, open a confirmation, and press a button. It is not
an Execute button with a longer name: it populates a selection you own and can edit.

### A selection cannot cross a sender

Every identifier in a selection came from one sender's review screen, and the session re-checks
that when it freezes the set. A selection that somehow named another sender's mail is **refused
whole**, not narrowed to the part that belongs: a confirmation built from the survivors would be
a confirmation of a set you never ticked.

---

## Sender-level review

Picking messages one at a time is right for a handful and tedious for forty. So a sender can hand
the review screen a **starting selection**, from two places:

- the sender inspector on the dashboard;
- a sender's row in the dry-run preview, where you have just read "38 of 43 would be archived".

Both are called **Review messages to archive…**, and the wording is the design. They are not
*Archive sender*, *Clean sender*, *Archive all from sender*, or *Apply recommendation*, because
none of those is an operation InboxSweep has. Pressing one opens a screen. It sends nothing,
freezes nothing, and starts nothing.

### Where the candidates come from

From the preview you were already looking at, not from a second engine written for this. The
candidates are the messages that sender's **current** dry run says the **selected action** would
affect, minus anything protected:

- one sender, and the key is re-checked when the set is frozen;
- the window currently loaded, so a deeper load or a reload changes them;
- the conceptual action shown in the preview, cutoff and keep-newest alike;
- never a protected message;
- only identifiers already in the loaded window;
- deterministic: the review list's own order, filtered in place.

They are recomputed every time the button is pressed. A proposal generated before a reload cannot
bring a stale list onto the screen.

### Preselection is not authorization

The review screen opens with those rows ticked, a line saying how many were ticked and how many
protected messages were left out, and every control it has always had. You can untick anything,
tick anything the rules missed (including a protected message), sort, filter, and change the
previewed action. Nothing is written at any point in that: not when the sender action is pressed,
not when the candidates are derived, not when the boxes are ticked, not when you change them, and
not when the confirmation opens.

The steps between a sender and a changed mailbox are unchanged by this feature. There are still
five, and you take all of them.

### When nothing is preselected

A sender-level action can legitimately find nothing to tick, and it says which of these it was
rather than showing an empty screen:

| Why | What the screen says |
| --- | --- |
| No loaded messages from that sender any more | The window may have been reloaded, or their mail may have left it |
| The action moves no messages (reviewing a subscription) | Choose an action, or tick messages yourself |
| Every loaded message is outside the action's scope | That action reaches none of the N loaded messages |
| Every loaded message is protected | All of them are held back; you can still tick them yourself |
| The action reached some, and protection held back all of those | How many were held back, and that the rest are out of scope |

**No fallback selection is ever manufactured.** "Nothing is selected" is a correct answer for a
sender whose mail is all recent or all starred, and inventing something to tick so the screen
looked useful would be the app choosing.

### What the confirmation says

Alongside the exact list, the count, and any protected-message warning:

> Only the messages listed here will be changed. Future messages from this sender are not
> affected: this archives the listed messages once, and creates no rule.

That is true because there is nothing on this path that could make it false. Confirming an
archive creates no Gmail filter, stores no rule, and schedules nothing.

The app does have one way to authorize future behaviour, and it is deliberately not this one: a
[sender rule](Rules.md), which you create on its own review screen after reading exactly what it
would do. This confirmation is not that screen and cannot become it.

### Nothing sender-shaped reaches Gmail

A sender-reviewed archive produces exactly the traffic that ticking the same messages by hand
produces: one `messages/{id}/modify` per message, with `{"removeLabelIds":["INBOX"]}`. There is no
sender-level provider method, no sender identifier in any URL or body, no query, no batch, no
thread call, and no filters or settings request. The sender is UI and domain context; it is not a
mutation concept, and `SafetyBoundaryTests` reads the bytes to prove it.

---

## Protected messages

Protection stays meaningful even though archiving is reversible, and the distinction the app
draws is between **the app choosing** and **you choosing**:

- **No convenience action ever selects a protected message.** Fill from preview skips anything
  starred, marked important, or that looks like part of a conversation, even when the previewed
  action's scope would otherwise reach it. This is checked twice: the planner holds protected
  messages back, and the preselection filters on protection again, so the guarantee does not
  depend on the planner continuing to order its filters the way it does today.
- **You can still tick one yourself.** It is your mail, and a heuristic being confident is not a
  reason for an app to refuse to archive your own message. Archiving is reversible, undoable, and
  not deletion.
- **The confirmation says so, in as many words**, listing how many protected messages are in the
  set and marking each one in the list. If that warning is on screen, somebody ticked it
  deliberately, and the warning's job is to check that they meant to, not to argue.

The review screen also shows a running count of protected messages in the current selection, so
the fact does not first appear at the confirmation.

---

## The confirmation

1. Open a sender.
2. Open **Review…** to see its loaded messages, or **Review messages to archive…** to open the
   same screen with the current preview's messages already ticked.
3. Tick the messages you want archived: individually, with **Select all shown**, with
   **Fill from preview**, or by editing what a sender-level action ticked for you.
4. Press **Archive N messages…**.
5. Read the confirmation.
6. Press **Archive N messages**.

The confirmation names the sender, the number of messages, and **every message in the set** by
subject and received date: the whole list, never "and 34 more". A confirmation you cannot read
in full is not a confirmation, so the sheet scrolls instead of summarising. It states plainly:

> These messages will be removed from your Inbox. They will not be deleted.

### The set is frozen

Between opening a confirmation for twelve messages and pressing the button, a page can land, a
reload can finish, and the review list underneath can become a different list. A confirmation
wired to live state would then be showing one set while archiving another, and you would have no
way to tell.

So the confirmation is wired to an **immutable snapshot** copied out of the window at the moment
you asked to review the set. Nothing recomputes it and nothing refreshes it. **The list on screen
is the list that gets archived, or nothing does.**

The snapshot carries what it takes to notice the window moving underneath it: the exact message
identifiers with the subject, date, and protection reason each had when you reviewed them; the
account the window was read for; the sender they all belong to; the mailbox scope that was loaded;
and one operation identifier, which is what makes a repeated press recognisably the same operation
rather than a second one.

### What is re-checked immediately before anything is sent

- the authenticated account still matches: asked of the provider, not read from the snapshot,
  because the snapshot records which account the window was *read* for and the question is which
  account the token authenticates *now*;
- the archive permission is still granted;
- the loaded scope is still the one the set was frozen under. Switching from Inbox to All mail
  leaves every identifier present and this sender's, and makes the list you read a list of
  something else;
- every message is still loaded, still in scope, and still belongs to the expected sender;
- every message is still in the Inbox. One archived elsewhere since the review, in the Gmail web
  app, on a phone, by a filter: would produce a request whose answer you could not tell apart
  from the one you asked for;
- **this confirmation has not already been carried out.** One confirmation is one operation, for
  the life of the session rather than only while its result is on screen.

If any of that has changed the operation is **refused whole and re-reviewed**. It is never
narrowed to the messages that still match: acting on "the ones still there" would be acting on a
set nobody approved. Nor is it quietly re-derived from a fresher planner run: that would be
executing a set you have not seen.

### While it is running

- The sheet is modal, so the selection cannot change under the confirmation.
- A second submission is refused by the session itself in two ways: nothing runs while something
  is running, *and* a frozen set that has already been executed cannot be executed again. The
  second guard is the one a disabled button misses, because by then nothing is in flight and the
  sheet is still on screen showing the same confirmed set.
- **Stop is a real button**, because sequential execution makes it a real promise: it stops
  before the next message. The request already with Gmail cannot be recalled, and the sheet says
  exactly that rather than implying otherwise. Messages never sent are reported as "not sent",
  which is a knowably unchanged state: distinct from "failed", where Gmail was asked and said no.
- Nothing on screen changes until Gmail confirms each message. There is no optimistic update, so
  a failure needs no rollback and a success is never claimed early.

---

## Partial failure

A set does not succeed or fail. **Twelve selected with four refused is eight real changes to your
mailbox**, and reporting that as "archiving failed" would tell you the opposite of what happened
to the other eight.

So every message gets its own outcome, and the result reads:

```
12 selected     8 archived     4 failed
```

with each row marked and given the app's own one-line reason, never Gmail's response body, an
authorization code, or a token. Three outcomes are distinguished:

| Outcome | Meaning |
| --- | --- |
| **Archived** | Gmail confirmed it. The message has left your Inbox. |
| **Failed** | Gmail was asked and refused. The message is unchanged and still in your Inbox. |
| **Not sent** | No request was ever made: you stopped the run, or a session-wide failure made the rest pointless. Knowably unchanged. |

### What a partial run does and does not do

- **Local state reconciles only the messages Gmail confirmed.** Failures keep the labels they
  had, so they stay in your Inbox locally exactly as they are remotely, and a refresh converges
  on the same state.
- **Successes are never rolled back** because something else failed. Those messages really did
  leave your Inbox; putting them back would be the app rewriting history it does not own, and
  would be more writes nobody asked for.
- **Failed messages are offered again where that makes sense.** A rate limit or a dropped
  connection is worth retrying; a message Gmail no longer has, or an account that changed, is
  not, and is not offered.
- **The undo transaction names the successful subset only**, eight identifiers for eight
  archived messages.

### When a run stops early

A failure about *this message* (throttling, a dropped connection, a message Gmail no longer has)
says nothing about the next one, so the run continues and each message gets its own answer.

A failure about *the session* (a withdrawn grant, an expired authorization, a swapped account)
is true of every message at once. The run stops rather than sending eleven more requests that are
all going to be refused identically, and the remainder are reported as **not sent**.

---

## Undo, and how long it lasts

Undo is a real Gmail request per message, through the same boundary the archive went through,
not a local correction. It restores **only** the messages that transaction confirmed. Nothing is
inferred into the set: not the rest of the sender, not the rest of a thread, not messages
archived by an earlier operation.

### It survives a relaunch

This is the change from the previous version, and it is deliberate. The offer used to live in
memory and end when the sheet closed or the window reloaded. It is now backed by the local
transaction file, so it survives:

- dismissing the result sheet;
- navigating elsewhere in the app;
- reloading the mailbox;
- quitting InboxSweep and reopening it.

Closing a sheet is how you get back to your mailbox, not how you say the archive was what you
wanted. The standing offer appears on the sender review screen as well as in the sheet that
created it, because an offer only findable inside a dismissed sheet is an offer nobody can find.

### What has to be true before it is offered again

On every published window the app re-derives the offer from the file, and all four must hold:

1. the transaction belongs to the account connected **now**;
2. it is an archive that confirmed at least one message;
3. it is still in the `undoable` state;
4. the grant still covers archiving: undo is a write like any other.

If the permission has been withdrawn from your Google Account since, the offer is withheld rather
than shown and then failing when pressed. The transaction itself stays in the file.

### The lifecycle: one undoable archive per account

| Event | What happens to the offer |
| --- | --- |
| You archive something else | The previous transaction is **superseded**; only the newest is undoable |
| The undo completely succeeds | Marked **undone**; no offer remains |
| The undo partly succeeds | **Narrowed** to the messages still archived, and still offered |
| The undo completely fails | Unchanged: those messages really are still archived |
| An archive confirms nothing | Unchanged: a failed run does not withdraw an unrelated offer |
| You disconnect | The transactions are deleted with everything else for that account |

A superseded transaction is **kept in the file, not deleted**: it is still a true record of what
the app did to your mailbox, and the audit history is why the file exists. But only one
transaction is ever in the `undoable` state, so the UI never claims two independent undos are
available. There is no unlimited undo history and no undo stack.

### Narrowing the offer does not rewrite the history

Both "narrowed" rows above shrink a transaction's list of message identifiers, because that list
means *the messages this archive still has out of your Inbox*: a second undo must not ask Gmail
about messages that already came back.

What it does **not** touch is what the archive did. The count it confirmed is fixed at the moment
Gmail answered, so an archive of ten that had four put back still reads "Archived 10 messages"
rather than "Archived 6 of 10", which would describe a partial archive that never happened. That
distinction is what lets one set of records serve both the undo and the
**[Activity](Activity.md)** screen without the two disagreeing.

Undoing an undo is not offered. Its inverse is archiving, and archiving is something you ask for
explicitly.

### An undo can itself partly fail

The same three outcomes apply: **restored**, **failed to restore**, and **not sent**. Local state
reconciles per message: the ones that came back are back in the Inbox, the ones that did not are
still archived, and the offer narrows to exactly what remains, never re-widening to include
messages already restored. Pressing Undo again asks only about those.

A message Gmail no longer has is reported as no longer applicable and is not retried, since
repeating that request is certain to fail the same way.

---

## Local reconciliation

After Gmail confirms, and only then, the app recomputes everything derived from the loaded
window, through the same code path a newly-loaded page goes through:

- each confirmed message's labels are **replaced with the ones on Gmail's reply**, not with the
  ones the app expected, so the window says what the mailbox says;
- messages Gmail refused are **not touched at all**, which is what makes a partial run produce a
  matching partial local state;
- the sender summary, the proposal, the protection verdicts, and dry-run membership are all
  recomputed over the smaller window;
- the saved plan is re-checked for staleness;
- the cache file is rewritten with the confirmed state.

Archived messages stay in memory with their new labels and drop out of the *Inbox-scoped* window,
rather than being deleted from it. Membership is derived by `MailboxScope.retains`, which is what
makes undo restore each message to its original position instead of appending it to the end. Only
the Inbox scope can lose a message this way: Gmail's category labels survive an archive untouched
and *All mail* lists archived mail by definition, so a message archived while one of those scopes
is loaded stays in the window, which is what a refresh would return.

A subsequent reload from Gmail therefore agrees with what is already on screen, including after a
partial run: the eight that were archived are gone from the Inbox list and the four that were
refused come back in it, which is exactly what local state already said.

### If the mailbox changed but this Mac could not write it down

Reported as a **success with a caveat**, never as a failure. Gmail changed the mailbox; saying
otherwise because the local record could not be written would tell you the opposite of what
happened to your mail.

It matters more than it used to, because the undo offer is read back out of that file. So the
caveat says both halves: the change is real, undo still works while the sheet is open, and it
will not be offered again after you quit.

---

## The local mutation transaction

A small file inside the app's own container, holding one line per completed operation. It is both
a receipt drawer and the thing that makes undo survive a relaunch.

**Stored:** a logical operation ID, the operation (`archive` / `restoreToInbox`), the account
address, the provider message IDs Gmail **confirmed**, how many messages were selected, a
timestamp, and the undo state.

**Not stored:** subjects, senders, received dates, labels, message bodies. The mailbox cache
already holds the metadata for every message in the loaded window, so copying subjects in here
would put the same content in a second file for no gain. A transaction *names* messages; the
window describes them. Growing from one message to many did not grow what a transaction knows
about mail, and `SafetyBoundaryTests` asserts the exact field list.

**Only successes are named.** A partial run stores eight identifiers for eight archived messages;
the four that failed are counted, not named, because there is nothing to undo about a message
that never changed. That is what makes undo safe to act on directly, every identifier in the
file is a message this app really did take out of your Inbox.

It is bounded to the 50 most recent entries, written atomically with `0600` permissions, excluded
from backups, keyed by a digest of the account address, and deleted when you disconnect. Runs
that confirmed nothing are recorded too: an attempt Gmail rejected is a fact about what the app
tried to do.

Transactions are replaced by operation ID rather than appended, which is what makes a repeated
completion safe (one logical mutation is one transaction) and is also how the undo lifecycle is
written down: superseding one and marking another undone are both just writes of a known ID.

### The reader is strict, on purpose

What comes out of this file becomes a list of messages the app sends requests about, so an entry
that is not unambiguously something InboxSweep wrote is **dropped rather than partly honoured**:
an unknown operation, an unknown undo state, a malformed ID, an empty or duplicated message
identifier, more confirmed than were selected, or a count larger than any run could produce. A
dropped entry costs an undo offer; a guessed one would mean asking Gmail about messages nobody
confirmed.

Files written by the previous schema version are discarded rather than migrated. They held
single-message records whose undo offers had already expired by design, so there is nothing in
one worth carrying forward.

This is not analytics. Nothing is aggregated, scored, or sent anywhere.

---

## Account isolation

A mutation is tied to the account the message was loaded from, and that is checked three times:

1. **In the session**, against the authenticated account as it is *now*: asked of the provider
   rather than taken from the snapshot, because the snapshot records which account the window
   was read for and the question is which account the token authenticates today.
2. **At the mutation boundary**, which holds the token and re-checks the request's account
   address against its own connection. A caller cannot opt out of this.
3. **During a permission upgrade**, which refuses (without disturbing the current session) if
   re-authorizing lands in a different Google account.

A set carries **one** account address rather than one per message, so every message in a set is
guaranteed to be checked against the same account.

If the account changes between selecting messages and confirming them, the operation is refused
whole and you are asked to review again. Every selected message must also still be in the loaded
window and still belong to the same sender, and the grant must still cover archiving. An undo is
checked the same way: a transaction stored for one account is never offered, or executed,
against a different one.

---

## Errors

Every failure is distinguished because each has a different recovery, and every one states that
the mailbox was **not** changed. Raw Gmail response bodies, authorization codes, and tokens
never reach the screen.

| Failure | What you are told to do |
| --- | --- |
| Mutation permission not granted | Grant the extra permission, then try again |
| The user declined the upgrade | Grant it later; everything else still works |
| Authorization expired or withdrawn | Connect your account again |
| The connected account changed | Reload, reopen the sender, pick the message |
| The message is no longer in the loaded window | Reload and choose it again |
| The confirmed set no longer matches the window | Reload, reopen the sender, choose the messages again |
| This confirmation was already carried out | Close it; if some messages were not archived, select those again |
| Gmail no longer has the message | Reload to see what is actually in your Inbox |
| Rate limited | Wait a moment and try again |
| Network failure or timeout | Check your connection, then reload to confirm what Gmail has |
| Gmail rejected the request | Reload to confirm what Gmail has, then try again |
| Cancelled before the request went out | Choose the message again whenever you are ready |
| Remote success, local record not written | Nothing: the change is real; reload if anything looks stale |

---

## Recommendations are still not executable

| Advisory: describes, cannot act | Executable: acts, after you confirm |
| --- | --- |
| Sender cleanup proposals | Archiving the messages you ticked and confirmed |
| Dry-run cleanup previews | Undoing that archive |
| Saved plan selections | |
| Protection verdicts | |
| **Fill from preview** (ticks boxes only) | |
| **Review messages to archive…** (opens a review with boxes ticked) | |

A saved plan naming "archive messages older than 30 days" still only reopens a preview when it is
restored. There is no code path from a proposal, a plan, or a recommendation to the mutation
boundary, and `SafetyBoundaryTests` exercises loading, previewing, saving, restoring, re-sorting,
reloading, preselecting from every action, and freezing a confirmation for every sender against a
recording archiver that must come back empty.

The workflow a recommendation can reach, and where it stops:

1. the preview says 38 messages would be affected;
2. **Review messages to archive…** opens those messages in review with them already ticked, minus
   anything protected;
3. you inspect the list, untick, tick;
4. you open a confirmation showing the frozen set, which says only the listed messages change and
   that future mail from that sender is unaffected;
5. **you** press the button.

Steps 1–4 send nothing. Step 5 is the only thing in the app that reaches Gmail with a write.

**Not implemented, and not reachable:** archive a whole sender in one click, archive all, execute
plan, apply recommendations, cross-sender bulk cleanup, sender rules, future-message automation,
`batchModify`, automatic archive, scheduled cleanup, background mutation, trash, permanent delete,
mark read/unread, and unsubscribe execution.

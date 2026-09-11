# Archiving a message

InboxSweep's first and only ability to change a mailbox: removing **one message you explicitly
confirm** from your Inbox, and putting it back.

Everything else in the app still reads, reasons, and describes. The cleanup proposals and the
dry-run planner remain advisory and have no execution path — they can lead you to the screen
where you archive a single message, and they stop there.

---

## What archiving does

In Gmail, a message is in your Inbox exactly when it carries the `INBOX` label. So archiving a
message *is* removing that label, and that is the whole of what InboxSweep does:

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
body is not a parameter — `GmailMutationRequest.InboxLabelChange` holds two literal constants —
so "add or remove `INBOX` on one named message" is the app's entire mutation vocabulary rather
than a convention someone has to maintain.

| Archiving does | Archiving does not |
| --- | --- |
| Remove `INBOX` from the one message you confirmed | Delete the message |
| Leave it in All Mail, in search, and under every other label | Move it to Trash |
| Leave its read state, star, importance, and Gmail category untouched | Mark it read or unread |
| Act on that message alone | Act on its thread, its sender, or anything else |

### Message-level, not thread-level

Gmail also offers `users.threads.modify`, which archives every message in a conversation.
InboxSweep does not use it. You picked one message in the review list; archiving the others in
its thread would be doing more than you asked. A conversation whose other messages are still in
your Inbox therefore stays in your Inbox — which is Gmail's own behaviour for archiving a single
message, and is what the confirmation says.

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
alternative to `gmail.modify` is not a smaller scope — it is not having an archive feature.

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
- granting it persists the widened scope through the existing Keychain credential store —
  including in the usual case where Google issues no new refresh token, where the working
  refresh token is kept and only the scope record is updated.

Granting the permission archives nothing. Consenting and archiving are two separate presses, on
purpose.

A stored grant that no longer covers *reading* is still discarded and still asks you to connect
again, as before.

---

## The confirmation

Archiving starts from an individual message in the sender message review — the screen that
already exists for looking at individual messages. No proposal, sender row, dry-run plan, or
saved plan can open the confirmation; only selecting a row and pressing **Archive message…**
does.

1. Open a sender.
2. Open **Review…** to see its loaded messages.
3. Select one message.
4. Press **Archive message…**.
5. Read the confirmation, which names the message by **sender, subject, and received date** and
   states that archiving removes it from your Inbox and does not delete it.
6. Press **Archive message**.
7. One request goes to Gmail. The result — and **Undo archive** — appear in the same sheet.

### While it is running

- The sheet is modal, so the message cannot change under the confirmation.
- A second submission is refused by the session itself, not only by a disabled button, so a
  double-click is one mutation and one record however fast the clicks arrive.
- **There is no Cancel once the request is out.** Gmail may already have applied it, and a
  Cancel that could not recall what it interrupted would be a worse promise than none. The sheet
  says so instead. Cancellation is meaningful only before the request is sent, and that case is
  reported as a cancellation.
- Nothing on screen changes until Gmail confirms. There is no optimistic update, so a failure
  needs no rollback and a success is never claimed early.

---

## Undo

Undo is a real Gmail request through the same boundary, not a local correction. It succeeds only
when Gmail confirms, and its failure is reported separately from the archive's success: the
archive really did happen, and putting the message back on screen because the undo failed would
be the app rewriting history it does not own.

**The undo lifetime is explicit and not time-based.** The offer lives in memory and ends when:

- the undo succeeds;
- another message is archived;
- the window is reloaded, the scope changes, or the account disconnects;
- you dismiss the result;
- the app quits.

It is deliberately not persisted and has no timer. A timer would expire the offer at a moment
you cannot see, and restoring it after a relaunch would mean offering an undo for a mailbox
state the app has not re-read and cannot vouch for. Once the offer is gone, the message is in
All Mail like any other archived message, and moving it back is something Gmail itself does
well.

---

## Local reconciliation

After Gmail confirms — and only then — the app recomputes everything derived from the loaded
window, through the same code path a newly-loaded page goes through:

- the message's labels are **replaced with the ones on Gmail's reply**, not with the ones the
  app expected, so the window says what the mailbox says;
- the sender summary, the proposal, the protection verdicts, and dry-run membership are all
  recomputed over the smaller window;
- the saved plan is re-checked for staleness;
- the cache file is rewritten with the confirmed state.

The archived message stays in memory with its new labels and drops out of the *Inbox-scoped*
window, rather than being deleted from it. Membership is derived by `MailboxScope.retains`, which
is what makes undo restore the message to its original position instead of appending it to the
end. Only the Inbox scope can lose a message this way: Gmail's category labels survive an
archive untouched and *All mail* lists archived mail by definition, so a message archived while
one of those scopes is loaded stays in the window — which is what a refresh would return.

A subsequent reload from Gmail therefore agrees with what is already on screen.

### If the mailbox changed but this Mac could not write it down

Reported as a **success with a caveat**, never as a failure. Gmail changed the mailbox; saying
otherwise because the local record could not be written would tell you the opposite of what
happened to your mail. The undo offer stands, and the sheet says the change is real.

---

## The local mutation record

A small file inside the app's own container, holding one line per attempted mutation:

**Stored:** a logical operation ID, the operation (`archive` / `restoreToInbox`), the provider
message ID, the account address, a timestamp, and whether Gmail confirmed it.

**Not stored:** the subject, the sender, the received date, any labels, any message body. The
mailbox cache already holds the metadata for every message in the loaded window, so copying a
subject in here would put the same content in a second file for no gain. A record *names* a
message; the window describes it.

It is bounded to the 50 most recent entries, written atomically with `0600` permissions,
excluded from backups, keyed by a digest of the account address, and deleted when you
disconnect. Failed attempts are recorded too — an attempt Gmail rejected is a fact about what
the app tried to do.

Records are replaced by operation ID rather than appended, which is what makes a repeated
completion safe: one logical mutation is one record.

This is not analytics. Nothing is aggregated, scored, or sent anywhere.

---

## Account isolation

A mutation is tied to the account the message was loaded from, and that is checked three times:

1. **In the session**, against the authenticated account as it is *now* — asked of the provider
   rather than taken from the snapshot, because the snapshot records which account the window
   was read for and the question is which account the token authenticates today.
2. **At the mutation boundary**, which holds the token and re-checks the request's account
   address against its own connection. A caller cannot opt out of this.
3. **During a permission upgrade**, which refuses — without disturbing the current session — if
   re-authorizing lands in a different Google account.

If the account changes between selecting a message and confirming it, the operation is refused
and you are asked to review again. The selected message must also still be in the loaded window,
and the grant must still cover archiving.

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
| Gmail no longer has the message | Reload to see what is actually in your Inbox |
| Rate limited | Wait a moment and try again |
| Network failure or timeout | Check your connection, then reload to confirm what Gmail has |
| Gmail rejected the request | Reload to confirm what Gmail has, then try again |
| Cancelled before the request went out | Choose the message again whenever you are ready |
| Remote success, local record not written | Nothing — the change is real; reload if anything looks stale |

---

## Recommendations are still not executable

| Advisory — describes, cannot act | Executable — acts, after you confirm |
| --- | --- |
| Sender cleanup proposals | Archiving one selected message |
| Dry-run cleanup previews | Undoing that archive |
| Saved plan selections | |
| Protection verdicts | |

A saved plan naming "archive messages older than 30 days" still only reopens a preview when it
is restored. There is no code path from a proposal, a plan, or a recommendation to the mutation
boundary, and `SafetyBoundaryTests` exercises loading, previewing, saving, restoring, re-sorting,
and reloading against a recording archiver that must come back empty.

**Not implemented, and not reachable:** archive a sender, archive all, execute plan, apply
recommendations, batch modify, automatic archive, scheduled cleanup, background mutation,
trash, permanent delete, mark read/unread, and unsubscribe execution.

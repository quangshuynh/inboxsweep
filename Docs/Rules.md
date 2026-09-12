# Sender rules

A rule is the one thing InboxSweep does to your mailbox without asking at the time. You create
each one yourself, on a screen that prints exactly what it will do, and you can turn it off or
delete it in one press.

**The governing rule:** InboxSweep may suggest that a rule could be useful. Only you can create
one, and a suggestion never becomes a rule on its own.

---

## What a rule is, and the three things it is not

A rule says: *when InboxSweep loads a new Inbox message from this exact address, archive it.*

It is **not a Gmail filter.** InboxSweep holds no Gmail settings permission and can create
nothing in your Google account. A rule is a few lines in a file on your Mac and means nothing to
Gmail.

It is **not a schedule.** Nothing in InboxSweep runs on its own: no background process, no login
item, no timer that outlives the app. See [When a rule runs](#when-a-rule-runs), which is the
part of this feature most easily overstated.

It is **not a proposal.** A proposal is the app's opinion, recomputed every launch and never
stored. A rule is your decision, stored because it is yours.

---

## When a rule runs

**When InboxSweep loads mail, which is when you open it or press Reload.**

That is the whole of it, and the app says so on the rule review, on every row in Rules, and in
the summary it shows after a pass. Matching mail arrives in your Inbox exactly as it always did,
and it is archived the next time you look.

What InboxSweep will never say, because it would not be true:

> Future messages will automatically skip your Inbox.

They will not. Skipping an Inbox requires something running while the app is closed, and the only
way to get that is a server-side Gmail filter, which needs a settings permission this app
deliberately does not request. If you want mail to never reach your Inbox, create a filter in
Gmail itself; InboxSweep will not do it for you and cannot.

---

## Exact identity, and nothing that resembles it

A rule matches on **equality** with the normalized sender address, and on nothing else.

| This | Does not match a rule for `deals@example.com` |
| --- | --- |
| `deals@mail.example.com` | A subdomain is a different host |
| `deals@example.com.example.org` | A suffix is not the address |
| `deals+offers@example.com` | Sub-addressing is preserved, so it is a different address |
| `sales@example.com` | A different local part |
| Anything with the display name "Storefront Deals" | Display names are never matched |

There is no domain match, no prefix match, no subject keyword, no category, and no similarity
score anywhere in the matching code. A sender changing their display name changes nothing,
because the address did not change.

Senders whose address InboxSweep could not parse share one grouping key, and that key is refused
at both ends: the review will not freeze a rule for it, and the matcher will not act on one. A
rule on "anything whose header did not parse" is precisely the fuzzy authority this feature
exists not to have.

---

## The one action

Archive a newly loaded Inbox message. That is the only value the action can hold, and it is an
enum with a single case rather than a parameter, so adding a second is a deliberate edit that a
test fails over.

A rule cannot, and has no code path to:

delete · trash · report as spam · mark read or unread · star · apply a label · forward · reply ·
send · block a sender · **unsubscribe**

The last one is worth stating on its own. Unsubscribing is authorized one action at a time, after
you have read the destination it will contact; a standing authorization to archive a sender is
not permission to contact them. See [Unsubscribing](Unsubscribe.md).

---

## What a rule refuses to touch

### Mail that arrived before the rule

A rule only ever acts on messages received **after** it was created. Create a rule for a sender
whose last four months are in front of you and none of those four months moves. This is a
timestamp comparison rather than a remembered list, so it gives the same answer on a window
loaded today as on one loaded next year.

Archiving the mail you already have is a separate thing you do from the message review, where you
tick the messages yourself and confirm the list.

### Protected mail

A rule **never** archives a message that trips a protection signal. Those are left in your Inbox
and InboxSweep tells you it left them.

The signals are the same ones the manual path uses, asked of the same function: a star you added,
a flag Gmail applied, a subject that reads like security, money, health, employment, government,
travel, or a receipt or order, or a subject that reads as part of a conversation.

The reasoning is worth being explicit about. You authorized a rule against a *sender*, at a
moment, on the evidence you had then. You did not authorize it against a specific message you
have never seen, and that message may be the one piece of mail from that sender that matters. A
rule that overrode protection would trade the app's most valuable safeguard for the convenience
of not seeing two messages in an Inbox.

You can still archive a protected message yourself, from the ordinary review, where the
confirmation says plainly that you are doing so.

### Mail that is not in the Inbox

Nothing to archive, so nothing is sent, and no Activity entry is written. A message somebody
archived in Gmail itself, or that a Gmail filter moved, is simply not a message this app did
anything to.

### A message it has already tried

One loaded message is sent to the boundary at most once per session, whether it succeeded or
failed. A message Gmail refused is tried again the next time you launch the app, and never in a
loop today.

---

## How a pass runs

One rule at a time, and one message at a time inside that, through the same message-level archive
boundary a person pressing **Archive** uses. Every request is the same `messages.modify` naming
one message; there is no sender endpoint, no batch call, and no thread mutation.

A pass archives at most **50** messages. Anything over the limit is left for a later load, which
is the same outcome as mail that had not arrived yet, and the summary says how many are waiting.
The limit exists because a first page is 250 messages and a deep load reaches thousands: without
it, a rule created for a long-dormant sender could turn one press of Reload into hundreds of
sequential writes against your Gmail quota.

Only changes Gmail confirmed are reconciled locally. A message that failed keeps whatever labels
it had, and the summary counts it as refused rather than archived.

### When something goes wrong

A failure about a single message does not stop the pass and does not disable anything.

A failure about the **session** (a withdrawn permission, a changed account, a cancelled load)
stops the pass and is reported. **No rule is ever disabled by a failure.** A rule is an
authorization you gave, and the app withdrawing one because Gmail was busy would be revoking a
decision it has no standing to revoke.

---

## Undo

**A rule-driven archive is not undoable, and the app says so rather than quietly offering
nothing.**

This is deliberate, and it is the one place where a rule is treated differently from an archive
you confirmed. InboxSweep keeps at most one undoable archive per account: a new archive supersedes
the previous offer. That invariant is safe while every archive is something a person just did,
because the offer they lose is one they replaced on purpose.

A rule is not that. It runs on every load, without anybody asking. Letting it take the offer would
mean a deliberate twelve-message undo disappearing because you pressed Reload and two newsletters
arrived. A second, parallel undo offer would be a larger change to the undo lifecycle than this
feature earns, and a screen offering two undos is a screen where somebody presses the wrong one.

So nothing is fabricated in its place. Activity says there is no undo and says why, and archived
mail is still in your Gmail account under **All Mail**, where Gmail's own **Move to Inbox** puts
a message back.

---

## Activity

A rule's work appears in Activity like any other change, and is labelled:

> Archived 3 messages from The Daily Digest **by rule**

with a line naming the rule underneath. Three properties of that wording are on purpose:

- It says **by rule**, never *by Gmail*. InboxSweep sent those requests, and a row implying Gmail
  did it on its own would be the app disowning a change it made.
- It says what was archived and stops. It does not claim your Inbox is now clear, because a pass
  knows what it archived and nothing about the rest of your mailbox.
- A row whose rule you have since deleted still says a rule did it. The archive happened, and
  deleting the authorization afterwards does not make it anonymous.

The domain model keeps three origins apart: an archive you ticked and confirmed, one you confirmed
from a sender-level review that filled the ticks in first, and one a rule performed. All three go
through the same boundary; only the last happened without a person in the room.

---

## Managing rules

**Rules** is reachable from the dashboard footer, beside Activity. Each row shows the address it
matches, what it does, whether it is on, when it was created, and what it can actually do right
now.

- **Turning one off** takes one press and no confirmation. It is the safe direction, and the rule
  is kept rather than deleted, because "pause this" and "I was wrong to create this" are different
  decisions.
- **Deleting one** asks first, because it throws away a decision you made on a review screen and
  cannot be taken back. Mail the rule already archived stays archived, and its Activity entries
  stay in the history.
- **Disconnecting** deletes every rule for that account along with the cached window, the saved
  preview, and the mutation history.

InboxSweep keeps at most 25 rules per account. Reaching that is a refusal, not an eviction:
dropping the oldest rule to make room would revoke an authorization you never withdrew. The limit
is about comprehension rather than size, since a rules screen you can read in one sitting is a set
of rules you can still be said to have authorized.

---

## Privacy: the one new thing on disk

A rules file is **the first thing InboxSweep has ever written down that names a sender.**

Everything else it stores describes no mail. The mutation history names messages by Gmail
identifier and holds no addresses, no subjects, and no dates received. The unsubscribe history
holds a destination host rather than a mailbox. Neither could tell you who you correspond with.

A rules file can, for as many senders as you have made rules about. That is unavoidable rather
than incidental: a rule's whole job is to recognise a sender, and there is no way to recognise one
without holding something that identifies them.

A digest was considered and rejected. It would be matchable but not *displayable*, and a rules
screen that could not tell you which sender each rule was about would be a list of authorizations
nobody could audit, which is worse for you than a file readable by your own user account.

So the exposure is bounded instead:

- at most 25 addresses, every one of them a sender you deliberately chose;
- no subjects, no message identifiers, no counts, and no record of what any rule has matched. A
  rule is an instruction, not a log;
- one file per account, named by a digest of the account address, so a directory listing does not
  name your mailbox;
- mode `0600`, excluded from Time Machine, deleted on disconnect;
- never synced, never sent anywhere, never aggregated. There is no analytics in this app.

---

## Creating one: derive, show, freeze, revalidate, authorize

The same pattern the unsubscribe review established, applied to the one decision whose
consequences outlive the screen that made it.

1. **Derive.** Opening the review reads the loaded window and returns a value. No file is written,
   no rule exists, and closing the sheet costs one allocation.
2. **Show.** The review prints the exact address, the exact action, when it can run, that existing
   mail is untouched, what it will not do to protected mail, and how to end it.
3. **Freeze.** The reviewed rule is fixed, identity and all.
4. **Revalidate.** Before it is saved, the account, the sender, the action, the scope, and the
   absence of an existing rule for that sender are all re-checked against the state as it is
   *then*. A frozen rule is saved unchanged or not at all; it is never adjusted to fit.
5. **Authorize.** Only an explicit press writes it, behind a second, dedicated confirmation.

There is exactly one call site that writes a rule, and it is the confirming button on that sheet.
No proposal, preview, saved plan, archive confirmation, or unsubscribe review can reach it.

---

## Limitations

- **A rule does nothing while InboxSweep is closed.** If that is what you want, you want a Gmail
  filter, which you create in Gmail.
- **A rule acts on what InboxSweep has loaded.** Mail beyond the loaded window is not matched
  until a load reaches it.
- **A rule cannot be created for a sender InboxSweep could not parse an address for.**
- **There is no undo for what a rule archives.** See [Undo](#undo).
- **Rules are per account and per Mac.** They are not synced, and signing in on another machine
  starts with none.

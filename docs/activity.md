# Activity

Activity is what InboxSweep has changed in this mailbox, newest first, read from the same local
transaction records that make [undo](archive-and-undo.md#undo) survive a relaunch.

It is a **reader**. Opening it, listing it, and opening a row send nothing to Gmail. The only
control on it that can reach a mailbox is the existing **Undo**, offered on the one transaction
the app already considers undoable. Being listed never makes an older change actionable.

!!! warning "Activity is what InboxSweep changed, not everything that happened in Gmail"

    Archive or restore a message in Gmail itself, in the web app, on a phone, or through a filter,
    and the next reload reconciles InboxSweep's view **without writing an entry claiming it did
    so**. A message can be absent from your Inbox without appearing here, and that is correct. A
    list of changes that quietly claimed credit for other people's work would be worse than no
    list at all.

## What it records

| Recorded | Meaning |
| --- | --- |
| A stable transaction identifier | One confirmation is one entry, however many times its button was pressed |
| The account it was performed for | Checked before an entry is shown **and** before an undo is sent |
| The operation | `archive` or `restoreToInbox`. There are no others |
| When it finished | The timestamp shown on the row |
| How many messages were selected | What you confirmed, including the ones that failed |
| How many were confirmed | What Gmail actually changed, fixed at the moment it answered |
| The messages still undoable | Provider identifiers, and only for messages still out of the Inbox |
| Its undo state | Whether an undo stands, was superseded, or has been carried out |

## What it does not record

**No mail.** No bodies, no snippets, no attachments, no raw provider responses. `MailMessage` has
nowhere to hold the first three, and Gmail's responses are normalized at the adapter boundary and
discarded.

Also, deliberately, **no subjects and no sender addresses**. They are not needed for correctness:
an undo acts on identifiers, and every count on the screen comes from numbers. Copying them into
the transaction file would put the same mailbox content in a second place purely so an old row
stayed descriptive. A row that says *Archived 3 messages* is worth more than three subjects kept
on disk forever.

### Where the subjects on a row come from, then

The local mailbox cache, resolved **at draw time**. When the loaded window still contains the
messages a transaction names, the detail view shows their subjects and dates. When it does not,
an archive from three months ago, a window since reloaded, a different scope, the row says so and
shows the counts, which never depended on the cache in the first place.

**History never depends on cache availability.** Losing the metadata costs you subjects, not
facts.

### "…from one sender"

A row reads *Archived 15 messages from one sender* only when the cache can still describe **every**
message the transaction names and they all turn out to have had the same sender. Otherwise it
reads *Archived 15 messages*.

The phrase is derived, with **nothing about a sender stored to make it possible**. The sender is
never named: "one sender" is the whole of it.

What it never says, because none of it would be true: that the sender was archived, that all of
that sender's mail was archived, or that anything the sender sends later is affected. A partly
undone archive does not get the phrase at all, because its identifier list is narrower than the
count in its headline and the two would describe different sets.

## Transaction states

| State | Meaning |
| --- | --- |
| **Undo available** | An archive whose messages InboxSweep can still put back |
| **Undo superseded** | A later archive replaced it as the account's undo offer. Its messages are still archived; there is no standing offer to reverse it |
| **Undone** | Every message this archive confirmed has been put back |
| **Partly undone** | Some have been put back and some have not |
| **Nothing changed** | Gmail confirmed nothing. No undo, because nothing happened |
| *(a restore)* | The record of an undo. Not itself undoable: its inverse is archiving, which you ask for explicitly |

There is deliberately **no state meaning "this message is in your mailbox now"**. A transaction is
a record of an operation, not a claim about where your mail is today.

### Partial operations stay partial

An archive of 10 that confirmed 8 reads *Archived 8 of 10 messages* forever. An undo of 4 out of
10 reads *Partly undone: 4 of 10 put back* forever. Neither is rounded up later.

This is less obvious than it sounds. A partial undo has to **narrow** the transaction's identifier
list, so a second undo asks Gmail only about messages that are still archived. Left alone, that
narrowing would rewrite the history underneath it: archive ten, put four back, and a screen
counting the remaining six would report *Archived 6 of 10*, a partial archive that never happened.
The confirmed count is the historical fact, fixed when the provider answered, and every count on
the screen derives from it.

### Undo and supersession

At most one transaction per account is ever undoable. A new archive that confirms anything
supersedes the previous offer; the superseded transaction stays in the history, because it is
still a true record of what the app did.

Activity does not change that rule. An older or superseded row shows its state and offers no
button. Undo appears only on the single transaction the session already considers undoable, for
the same account, still undoable, with the archive permission still granted, and it uses the
identifiers that transaction confirmed rather than anything reconstructed from what is on screen.

A [rule-driven](rules.md#undo) archive is labelled **by rule**, with the rule named underneath,
and is never undoable. It says *by rule*, never *by Gmail*: InboxSweep sent those requests.

## Retention

The **100 most recent entries per account**, on this Mac. Signing out deletes them, along with
every other local file.

The bound exists for the same reason every other bound in the app does: an unbounded local record
of what you did to your mailbox is a growing privacy cost with no growing benefit.

## Getting there

Activity is reachable from the toolbar **and** from a link in the dashboard footer, so the
question does not depend on a toolbar being easy to get at. The same is true of
[Rules](rules.md#managing-rules), which sits beside it.

Empty states say which kind of empty they are: an account that has changed nothing reads
differently from a filter that matched nothing.

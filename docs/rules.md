# Sender rules

A rule is the **one standing authorization** in InboxSweep. Everything else it can do is a single
act you confirmed at the time; a rule keeps acting, on mail nobody has read yet, until you turn
it off.

## What a rule is

| | |
| --- | --- |
| What it matches | **One exact normalized address.** No domain, prefix, display-name, subject, or similarity match anywhere |
| What it does | Archives a newly loaded Inbox message. One action, an enum with one case |
| When it runs | **While InboxSweep loads mail**, which is when you open it or press Reload |
| What it will not touch | Mail that arrived before the rule, protected mail, mail already out of the Inbox, or a message it has already tried this session |
| How it runs | One rule at a time, one message at a time, through the same message-level archive request a person pressing Archive makes. At most 50 messages a pass |
| Undo | **None**, deliberately, and Activity says so |
| Where it lives | A local file on this Mac, account-scoped, at most 25 rules, deleted when you disconnect |

## The three things it is not

!!! warning "A rule does nothing while InboxSweep is closed"

    **It is not a Gmail filter.** The app holds no permission to create one and cannot become one.
    Matching mail arrives in your Inbox as usual and is archived the next time you open the app or
    press Reload. If you want mail never to reach your Inbox at all, that is a filter you make in
    Gmail, and InboxSweep cannot make it for you.

**It is not a classifier.** Matching is an exact comparison against one normalized address. There
is no fuzzy matching, no domain rule, no "senders like this one", and no model.

**It is not a delete rule.** Its one action is archive, which is
[removing the `INBOX` label](archive-and-undo.md). The action is an enum with a single case, so a
rule that deleted something is not a value this app can construct.

## What a rule refuses to touch

### Mail that arrived before the rule

Every rule records when it was created, and it only ever considers messages received after that.
Creating a rule is authorizing what happens **next**, not a retroactive sweep of what is already
in your Inbox. A backlog is still yours to review and
[archive deliberately](archive-and-undo.md).

### Protected mail

A rule runs the same [protection](cleanup-proposals.md#step-1-protection-runs-first-and-can-only-veto)
check every other part of the app runs, and a protected message is skipped. You authorized
archiving a sender's mail; you did not authorize archiving the one message from them that looks
like a receipt, and the app would rather leave it than be right on average.

### Mail that is not in the Inbox

A message already archived, or read in another scope, is not touched. There is nothing to do, and
the request would be indistinguishable from one that failed.

### A message it has already tried

Within a session, a message a rule has attempted is not attempted again, whether it succeeded or
not. That is what stops a failing request being re-sent on every page of a load.

## How a pass runs

A pass runs while mail is being loaded, after the messages arrive and before the dashboard
settles. One rule at a time, one message at a time, through the same boundary a person pressing
Archive reaches, and capped at **50 messages per pass**.

The cap is not a performance number. It bounds how much can happen without you watching, which is
the whole thing a standing authorization needs bounded.

If something goes wrong, the pass stops rather than continuing to fire requests, and what it did
before stopping is recorded as what it was.

## Undo

**A rule-driven archive has no undo**, and this is a decision rather than an omission.

The app keeps [one undoable archive per account](archive-and-undo.md#undo). Letting something
automatic take that offer would mean an unattended pass could silently consume an undo you were
keeping for an archive you made yourself. Between the two, losing an undo you meant to keep is
worse than not being offered one for a change you authorized in advance.

Activity says so on the row rather than leaving you to discover it. What a rule archived is in
All Mail, and moving it back is a Gmail operation.

## In Activity

A rule's work appears in [Activity](activity.md) labelled **by rule**, with the rule named
underneath. It says *by rule*, never *by Gmail*: InboxSweep sent those requests, and a history
that blamed the mail provider for the app's own writes would be the one thing this record exists
to prevent.

## Managing rules

**Rules** is reachable from the dashboard footer, beside Activity. Each row shows what it matches,
what it does, whether it is on, and what it can actually do right now.

That last column matters: a rule is an authorization, not a capability. In a session with no
archive boundary, a rule is listed, inspectable, and **inert**, and the screen says so rather than
implying it is running.

Turning one off takes one press. Deleting one asks first.

## Creating one

Creating a rule takes a dedicated review screen and two deliberate presses. InboxSweep may suggest
that a rule could be useful; the affordance that says so **opens the review**, and the review
creates nothing.

The sequence is derive, show, freeze, revalidate, authorize:

1. **Derive** the candidate rule from the sender you are looking at.
2. **Show** the exact address it will match and the exact thing it will do, in full.
3. **Freeze** that into a snapshot, so what you read is what gets created.
4. **Revalidate** immediately before writing, the same way an
   [archive confirmation](archive-and-undo.md#what-is-re-checked-immediately-before-anything-is-sent)
   is revalidated.
5. **Authorize** with the confirming button.

There is exactly **one call site in the app that writes a rule**, and it is that button.

## The one new thing on disk

A rule has to name the address it matches. That makes the rules file the first thing InboxSweep
writes down that names a **sender** rather than a message identifier, and that cost is stated here
rather than buried.

How it is bounded:

- One file per account, in the app's sandbox container, `0600`, excluded from backups, named after
  a digest of the account address rather than the address itself.
- It holds the addresses you authorized, what each rule does, whether it is enabled, and when it
  was created. **No subject, no message, no mail.**
- At most 25 rules.
- Deleted when you disconnect, along with everything else.

The alternative would be a rule that cannot say what it matches, which is not a rule.

## Limitations

- A rule does nothing while the app is closed. This is the important one and it is repeated
  wherever it matters.
- One exact address per rule. A sender who mails you from several addresses needs several rules.
- No undo, as above.
- At most 25 rules and at most 50 messages per pass.
- A rule cannot unsubscribe, cannot delete, cannot label, and cannot act on a thread.
- Rules are local to this Mac and this account. They do not sync, and nothing at Google knows they
  exist.

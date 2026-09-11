# Cleanup proposals

How InboxSweep decides what to suggest, what stops it suggesting, and what a dry-run preview
does and does not tell you.

Everything here is computed from message *metadata*: sender addresses, subject lines, dates,
Gmail's own labels, and the presence of a `List-Unsubscribe` header. No message body is ever
requested, no AI is involved, and nothing leaves the Mac.

> **Still advisory.** A proposal and a preview describe; neither can carry itself out. The app
> can archive a **single message you open and confirm** (see [Archiving](Archiving.md)) and
> that is reached by looking at individual messages, never by acting on a proposal. It cannot
> archive a sender, run a plan, trash, label, mark, or unsubscribe.
> See [Why proposals are not executable](#why-proposals-are-not-executable).

For how a sign-in is stored and restored between launches, see
[Session restore](SessionRestore.md).

## What a proposal is

A proposal is InboxSweep's answer to *"is this sender worth cleaning up, and why?"* for one
sender, across the messages that have actually been loaded.

| Proposal | What it means |
| --- | --- |
| **Keep** | Nothing in the loaded window suggests cleaning this sender up, or something says not to. |
| **Review** | Something here is worth your eyes, but the metadata doesn't support a confident suggestion. |
| **Likely newsletter** | Reads like a mailing list you subscribed to. |
| **Likely promotional clutter** | Arrives in volume, filed under Promotions, with little sign of engagement. |
| **Likely recurring notification** | Automated status mail from a service. |
| **Possible cleanup candidate** | Several bulk-mail signals agree without matching a more specific pattern. |

Each proposal also carries a **strength**: *Limited*, *Moderate*, or *Strong evidence*,
which is the number of agreeing signals translated into a band. The count itself is never
shown, because a "cleanup score: 7" invites trust in arithmetic the reader cannot see.

Note what these names avoid. No proposal says a sender is spam, junk, useless, or safe to
delete. Metadata from a bounded window supports "this reads like a mailing list"; it does not
support "you do not need this".

## How a proposal is calculated

Rules live in
[`CleanupProposalEngine`](../InboxSweep/Domain/Proposals/CleanupProposalEngine.swift) and every
threshold in
[`CleanupProposalRules`](../InboxSweep/Domain/Proposals/CleanupProposalRules.swift). The engine
is pure, has no notion of "now", and calls nothing: the same loaded window always produces the
same proposals, with the same reasons in the same order.

### Step 1: Protection runs first

If the [protection rules](#protection-rules) find anything, they decide the outcome and no
amount of bulk-mail evidence overrides them.

### Step 2: Eight bulk-mail signals are counted

| Signal | Fires when |
| --- | --- |
| High volume | 8 or more loaded messages from the sender |
| Promotions category | Gmail filed this sender's mail under Promotions |
| List metadata | `List-Unsubscribe` on 60% or more of the loaded messages |
| Automated sender | The address' local part contains `noreply`, `notification`, `alert`, `mailer`, `automated`, `autoreply`, `postmaster`, `bounce`, or `daemon` |
| Recurring cadence | 4+ loaded messages with a mean gap between 6 hours and 45 days |
| Mostly unread | 70% or more still unread |
| No engagement markers | No starred, no Important, and no reply-shaped subjects |
| Wide window | The loaded messages span 30 days or more |

*Mostly unread* and *no engagement markers* are **absences**, and an absence observed over two
or three messages is not an observation, every sender who has written to you once has no
starred mail. Both are ignored below 5 loaded messages.

### Step 3: A pattern is matched, or not

Patterns are checked most-specific first, and **each requires three signals to agree**, so no
single observation can produce a cleanup-oriented suggestion:

| Pattern | Requires |
| --- | --- |
| Likely promotional clutter | Promotions category **and** high volume **and** (mostly unread **or** list metadata) |
| Likely newsletter | List metadata **and** recurring cadence **and** (high volume **or** wide window) |
| Likely recurring notification | Automated sender **and** recurring cadence **and** high volume |
| Possible cleanup candidate | 4 or more signals, matching none of the above |

Two further brakes apply before any of this:

- Fewer than **5 loaded messages** → never a cleanup proposal. Four messages cannot
  distinguish a mailing list from a colleague who happened to write four times.
- Gmail's own **Personal** category → never a cleanup proposal. That is Gmail saying this is
  correspondence.

Anything left over is *Review* at 2+ signals and *Keep* otherwise.

## Protection rules

Protection can only ever make InboxSweep more cautious. The rules are conservative on purpose,
and the conservatism is asymmetric: a false positive costs you a suggestion, while a false
negative would put mail you care about in front of a cleanup plan. Metadata classification is
not good enough to be even-handed about that trade.

| Signal | Detected from | Corroborated when |
| --- | --- | --- |
| Starred | A star you added | Always, one is enough |
| Marked Important | Gmail's own flag | Always, one is enough |
| Personal correspondence | Subjects beginning `Re:`, `Fw:`, `Fwd:` | 2+ such subjects, or 1 alongside Gmail's Personal category |
| Account or security | Subject phrases: sign-in alerts, verification codes, passwords, suspicious activity | 2+ messages, or every loaded message |
| Financial | Statements, invoices, payments, banking, billing | 2+ messages, or every loaded message |
| Receipts and orders | Order confirmations, shipping, tracking, refunds | 2+ messages, or every loaded message |
| Travel | Boarding passes, itineraries, bookings, flights | 2+ messages, or every loaded message |
| Government or tax | Tax, IRS/HMRC, court, social security, passports | 2+ messages, or every loaded message |
| Employment | Interviews, applications, recruiters, payroll | 2+ messages, or every loaded message |
| Healthcare | Appointments, prescriptions, results, claims | 2+ messages, or every loaded message |

The full phrase lists are in
[`SubjectTopic`](../InboxSweep/Domain/Proposals/SubjectTopic.swift): plain literal phrases,
matched on whole words, no regular expressions and no stemming, so a reviewer can read the
entire classifier in one sitting. ("Reorder your usual?" does not match *order*.)

### What protection does to a proposal

- **Corroborated signal → Keep.** InboxSweep will not propose cleanup for this sender.
- **Uncorroborated signal → Review.** A single subject-line match among many is a weak claim.
  Rather than confidently proposing cleanup, InboxSweep asks you to look.
- **One exception:** a protected sender that is *also* unmistakably bulk mail (a shop that
  sends forty offers and two order receipts) becomes **Review** rather than Keep. "Keep" would
  hide something you probably do want to see. It still proposes no cleanup.

### This is not a classifier you should trust blindly

InboxSweep matches words in subject lines. It has no idea what a message says, who sent it, or
what it is worth to you. It will miss a bank whose subjects are opaque, and it will flag a
newsletter about tax software. That is why a protection signal produces a *warning with its
evidence attached*: "3 loaded messages mention banking, billing, or payment topics in the
subject line", rather than a verdict.

## Explainable by construction

Every proposal carries its reasons as sentences, produced by the engine itself rather than
assembled next to the pixels. Reasons appear in a fixed order, protection always first, so a
sender's explanation reads identically on every launch.

Real examples from the synthetic mailbox:

> **Likely promotional clutter** · Strong evidence
> - 24 promotional messages from this sender in the loaded window
> - Gmail files this sender's mail under Promotions
> - Mailing-list unsubscribe metadata on every loaded message
> - About 1 message per day
> - 24 of 24 loaded messages still unread
> - No starred, important, or reply-like messages detected

> **Keep** · Strong evidence
> - 3 loaded messages are marked Important by Gmail
> - InboxSweep doesn't propose cleanup for senders with signals like these

> **Review** · Moderate evidence
> - 1 loaded message mentions receipts, orders, or deliveries in the subject line: a single
>   mention, so it may not be what it looks like
> - That's a single, uncorroborated signal, so this is flagged for review rather than cleanup

## Dry-run semantics

Selecting senders and choosing **Preview cleanup** builds a plan. A plan is a description:
counts and sentences, with no message identifiers to act on and no reference to a provider.
Building one reads messages already in memory and makes no request of any kind.

Four conceptual actions can be previewed:

| Action | Reaches |
| --- | --- |
| Keep only the newest 5 | Everything older than the newest 5 from that sender |
| Archive messages older than 30 / 90 days | Everything past that cutoff |
| Move messages older than 90 days to Trash | Everything past that cutoff |
| Review the subscription | Nothing: it is a prompt to look at the subscription itself |

For each sender the preview shows the proposed action, how many loaded messages it would
affect, how many would stay put, and **every retained message accounted for by a stated
reason**. The retained count is never a residual: the exclusions always sum to it.

The order of the two filters matters. An action's **scope** is applied first, and only what
survives is tested for **protection**. A starred message from yesterday is therefore reported
as "newer than the cutoff", not as "protected from a 90-day archive": the app does not take
credit for saving mail an action was never going to reach.

Message-level protection is necessarily narrower than sender-level: a message is held back if
*it* is starred, *it* is marked Important, *its* subject mentions a protective topic, or *its*
subject reads as a reply.

You can preview an action for a sender InboxSweep said to Keep. Previewing changes nothing and
you are allowed to look. The plan says so, and still excludes that sender's protected messages.

## Reviewing the messages behind a proposal

A count nobody can check is a claim. Selecting a sender and choosing **Review…**, or
**Review all…** from inside a preview, opens the loaded messages themselves.

Each row shows the subject, when it arrived, whether it is unread, starred, or marked
Important, the Gmail category it carries, any protection reason, and, when an action is
selected: what that action would do with it: *would be affected*, *held back*, or *out of
scope*.

Sort by newest, oldest, unread first, or subject. Newest and oldest lead because every offered
action is a question about age, and seeing the list in that order makes "keep only the newest
five" checkable rather than something to take on trust.

The same information appears inline in the preview, under **Which messages?**, split into
*Would affect* and *Protected / retained* with the reason beside each retained message.

Per-message verdicts and the counts above them come from a single pass over the same messages,
so a review can never disagree with the total it sits under. A test asserts this for every
offered action.

Nothing on the review screen acts. There is no body to show: `MailMessage` has nowhere to hold
one: the rows are not buttons, and opening a review makes no request of any kind.

## The loaded window is not your mailbox

Every count in a proposal or a plan describes the messages InboxSweep has **loaded**. It is not
the sender's total, and it is not your mailbox.

### Choosing how much to read

Two controls decide the window, and the dashboard states the result:

| Control | What it does |
| --- | --- |
| **Read** | Which slice to read: Inbox, Promotions, Updates, Social, Forums, or All mail |
| **Load** | How deep a **Load deeper** goes: 250, 500, 1,000, or as much as possible |
| **Load more** | One further page |
| **Load deeper** | Pages until the chosen depth is met, the provider runs out, or you stop |

Each scope maps to a label Gmail already applies: `INBOX`, `CATEGORY_PROMOTIONS`, and so on.
There is no search box and there could not be one: `gmail.metadata` rejects the `q=` parameter,
and widening the scope to gain search would mean asking for access to message bodies. The
category scopes are **Gmail's own classification**; InboxSweep reports what Gmail filed there
and does not classify mail itself.

Changing the scope discards the loaded window and reads the new one. A window that mixed scopes
would make every count on the dashboard describe something you could not name.

### There is a ceiling, and it is not "your whole mailbox"

Gmail's list endpoint returns identifiers only, so every message costs one further metadata
request. A thousand messages is a thousand requests.

**No depth reads more than 2,500 messages** (`MailboxLoadDepth.safetyLimit`). There is
deliberately no unbounded option: over a large mailbox that would be tens of thousands of
requests, which is how an account gets throttled and how a well-meaning button becomes an
accidental denial of service against its own user. Requests run at bounded concurrency, a page
budget stops a provider that keeps returning a cursor and no messages, and **Stop** keeps every
page already read.

### What the dashboard says about coverage

The load bar and the footer state the loaded count and whether there is more:

- **More to come:** "250 messages loaded. More messages are available in your inbox.
  Everything on this screen describes the 250 loaded so far."
- **Provider exhausted:** "1,000 messages loaded. That is everything InboxSweep could list
  from your inbox. Mail outside the inbox (already archived, sent, or filed under other
  labels) is not read."

The word *everything* appears only once the provider has actually run out of pages, and only
ever about the scope that was read. An exhausted inbox is still only the inbox.

Two consequences worth knowing:

- **Loading more can change a proposal.** Cadence, volume, and span are all measured over the
  window, so extending it can move a sender from *Review* to *Likely newsletter*, or surface a
  protective message that moves it to *Keep*. Proposals and protection are recomputed from the
  whole window after every page, so the dashboard always shows the current verdict rather than
  the first one it happened to compute.
- **A sender near the bottom of the window is under-counted.** A weekly newsletter going back
  two years contributes only its most recent issues to a 250-message window.

## Persistence

Proposals are **never stored**. They are recomputed from persisted message metadata on every
launch, which is cheap and means a change to the rules takes effect immediately rather than
leaving last week's verdicts on screen. The on-disk cache record has nowhere to put a proposal,
a reason, or a protection signal, and a safety test asserts that it stays that way.

`CleanupProposalRules.version` is carried on each proposal so the UI and the tests can state
which ruleset produced what they are showing.

### Saved planning choices

What *is* stored is the **choosing**. **Remember these choices** keeps which senders you
picked and what you chose to preview for each: sender grouping keys and an action identifier,
nothing more. The keep-newest count and the age cutoff travel inside the action, so they need
no separate storage.

One file per account, at most one account at a time, owner-only permissions inside the
sandboxed container, excluded from backups, named by a digest of the address, and deleted when
you disconnect. A plan written for one account is never offered to another: the file records the
address it belongs to and is discarded when that does not match.

**A saved plan is not a scheduled one.** Restoring one re-opens a preview. There is no
execution path in this app for it to trigger, nothing on the record that a schedule could hide
in, and `SafetyBoundaryTests` asserts that restoring one issues no provider call at all.

Choices go stale, and the app says so rather than quietly correcting:

| What changed | What happens |
| --- | --- |
| `CleanupProposalRules.version` | The plan is marked **out of date**. The reasoning you were reading when you chose is not the reasoning on screen now, so the saved actions are not used as seeds. |
| The scope | Said out loud; the choices still load. |
| A chosen sender left the loaded window | Dropped from the plan, and counted in the notice. |
| The window grew or shrank by more than a fifth | Said out loud, with both numbers: the same action reaches a different set of mail. |

The window tolerance is a fifth so that a page of new mail is not an interruption while a deep
load, which changes what every action reaches, always is. Staleness is re-evaluated after every
page, so a plan becomes visibly stale as a deep load runs.

## Why proposals are not executable

The app can now change one thing about a mailbox: whether a single message you selected and
confirmed is in your Inbox. Nothing on this page can reach that.

A proposal is a sentence about a sender. A plan is counts and sentences: `CleanupPlan` carries
no message identifiers, no provider, no schedule, and nothing that could stand in for one, and
neither does a saved plan. The dry-run planner runs entirely on the loaded window and makes no
request of any kind. The route from here to an actual change runs through **Review…** and then
through one message, one confirmation, and one press: a person, not a rule.

`SafetyBoundaryTests` asserts the whole of it: that the only two mutating requests the app can
build are `messages.modify` calls adding or removing `INBOX` on one named message; that neither
reaches a trash, delete, send, settings, batch, or thread path; that every read request is a
`GET`; that building a preview or reviewing a sender's messages issues no provider call at all;
that a plan and a saved plan are both inert data with nowhere for a schedule or an execution to
hide; that **restoring a saved plan whose action is literally called "archive" performs
nothing**; that loading, previewing, saving, restoring, re-sorting and reloading reach the
mutation boundary zero times; and that no proposal describes a sender in terms the evidence
cannot support.

The order was deliberate. Recommending well is a harder problem than deleting, and it was worth
getting right before anything was allowed to touch a mailbox, which is also why the first thing
allowed to is one message at a time, with an undo.

# Cleanup proposals

How InboxSweep decides what to suggest, what stops it suggesting, and what a dry-run preview
does and does not tell you.

Everything here is computed from message *metadata* — sender addresses, subject lines, dates,
Gmail's own labels, and the presence of a `List-Unsubscribe` header. No message body is ever
requested, no AI is involved, and nothing leaves the Mac.

> **Still read-only.** InboxSweep can recommend and preview. It cannot archive, trash, label,
> mark, or unsubscribe, and it holds no Gmail permission that would let it. See
> [Why this is still read-only](#why-this-is-still-read-only).

## What a proposal is

A proposal is InboxSweep's answer to *"is this sender worth cleaning up, and why?"* for one
sender, across the messages that have actually been loaded.

| Proposal | What it means |
| --- | --- |
| **Keep** | Nothing in the loaded window suggests cleaning this sender up — or something says not to. |
| **Review** | Something here is worth your eyes, but the metadata doesn't support a confident suggestion. |
| **Likely newsletter** | Reads like a mailing list you subscribed to. |
| **Likely promotional clutter** | Arrives in volume, filed under Promotions, with little sign of engagement. |
| **Likely recurring notification** | Automated status mail from a service. |
| **Possible cleanup candidate** | Several bulk-mail signals agree without matching a more specific pattern. |

Each proposal also carries a **strength** — *Limited*, *Moderate*, or *Strong evidence* —
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

### Step 1 — Protection runs first

If the [protection rules](#protection-rules) find anything, they decide the outcome and no
amount of bulk-mail evidence overrides them.

### Step 2 — Eight bulk-mail signals are counted

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
or three messages is not an observation — every sender who has written to you once has no
starred mail. Both are ignored below 5 loaded messages.

### Step 3 — A pattern is matched, or not

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
| Starred | A star you added | Always — one is enough |
| Marked Important | Gmail's own flag | Always — one is enough |
| Personal correspondence | Subjects beginning `Re:`, `Fw:`, `Fwd:` | 2+ such subjects, or 1 alongside Gmail's Personal category |
| Account or security | Subject phrases: sign-in alerts, verification codes, passwords, suspicious activity | 2+ messages, or every loaded message |
| Financial | Statements, invoices, payments, banking, billing | 2+ messages, or every loaded message |
| Receipts and orders | Order confirmations, shipping, tracking, refunds | 2+ messages, or every loaded message |
| Travel | Boarding passes, itineraries, bookings, flights | 2+ messages, or every loaded message |
| Government or tax | Tax, IRS/HMRC, court, social security, passports | 2+ messages, or every loaded message |
| Employment | Interviews, applications, recruiters, payroll | 2+ messages, or every loaded message |
| Healthcare | Appointments, prescriptions, results, claims | 2+ messages, or every loaded message |

The full phrase lists are in
[`SubjectTopic`](../InboxSweep/Domain/Proposals/SubjectTopic.swift) — plain literal phrases,
matched on whole words, no regular expressions and no stemming, so a reviewer can read the
entire classifier in one sitting. ("Reorder your usual?" does not match *order*.)

### What protection does to a proposal

- **Corroborated signal → Keep.** InboxSweep will not propose cleanup for this sender.
- **Uncorroborated signal → Review.** A single subject-line match among many is a weak claim.
  Rather than confidently proposing cleanup, InboxSweep asks you to look.
- **One exception:** a protected sender that is *also* unmistakably bulk mail — a shop that
  sends forty offers and two order receipts — becomes **Review** rather than Keep. "Keep" would
  hide something you probably do want to see. It still proposes no cleanup.

### This is not a classifier you should trust blindly

InboxSweep matches words in subject lines. It has no idea what a message says, who sent it, or
what it is worth to you. It will miss a bank whose subjects are opaque, and it will flag a
newsletter about tax software. That is why a protection signal produces a *warning with its
evidence attached* — "3 loaded messages mention banking, billing, or payment topics in the
subject line" — rather than a verdict.

## Explainable by construction

Every proposal carries its reasons as sentences, produced by the engine itself rather than
assembled next to the pixels. Reasons appear in a fixed order — protection always first — so a
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
> - 1 loaded message mentions receipts, orders, or deliveries in the subject line — a single
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
| Review the subscription | Nothing — it is a prompt to look at the subscription itself |

For each sender the preview shows the proposed action, how many loaded messages it would
affect, how many would stay put, and **every retained message accounted for by a stated
reason**. The retained count is never a residual: the exclusions always sum to it.

The order of the two filters matters. An action's **scope** is applied first, and only what
survives is tested for **protection**. A starred message from yesterday is therefore reported
as "newer than the cutoff", not as "protected from a 90-day archive" — the app does not take
credit for saving mail an action was never going to reach.

Message-level protection is necessarily narrower than sender-level: a message is held back if
*it* is starred, *it* is marked Important, *its* subject mentions a protective topic, or *its*
subject reads as a reply.

You can preview an action for a sender InboxSweep said to Keep. It is a read-only preview and
you are allowed to look. The plan says so, and still excludes that sender's protected messages.

## The loaded window is not your mailbox

Every count in a proposal or a plan describes the messages InboxSweep has **loaded** — 250
inbox messages by default, extended a page at a time by **Load more messages**. It is not the
sender's total, and it is not your mailbox.

The preview states which case applies:

- **More mail beyond the window:** "These figures describe only the 250 messages InboxSweep has
  loaded from your inbox. There is more mail beyond that window which the app has never read,
  so the real totals for these senders are higher."
- **Window exhausted:** "These figures cover all 250 inbox messages InboxSweep has loaded. Mail
  outside the inbox — already archived, sent, or filed under other labels — was never read and
  is not counted."

Note that even an exhausted window is only the *inbox*. InboxSweep never claims to have seen
your whole mailbox, because it has not.

Two consequences worth knowing:

- **Loading more can change a proposal.** Cadence, volume, and span are all measured over the
  window, so extending it can move a sender from *Review* to *Likely newsletter* — or surface a
  protective message that moves it to *Keep*.
- **A sender near the bottom of the window is under-counted.** A weekly newsletter going back
  two years contributes only its most recent issues to a 250-message window.

## Persistence

Proposals are **never stored**. They are recomputed from persisted message metadata on every
launch, which is cheap and means a change to the rules takes effect immediately rather than
leaving last week's verdicts on screen. The on-disk cache record has nowhere to put a proposal,
a reason, or a protection signal, and a safety test asserts that it stays that way.

`CleanupProposalRules.version` is carried on each proposal so the UI and the tests can state
which ruleset produced what they are showing. It is not a migration key; there is nothing to
migrate.

## Why this is still read-only

InboxSweep requests exactly one Gmail scope, `gmail.metadata`, which cannot modify a mailbox.
This interval adds no scope, no endpoint, and no code path that writes. The dry-run planner
operates entirely on local data.

`SafetyBoundaryTests` asserts all of it: that no mutating scope is requested, that every Gmail
request the app can build is a `GET` whose path reaches none of Gmail's mutating operations,
that building a preview issues no provider call and sends no HTTP request, that a plan is inert
data, and that no proposal describes a sender in terms the evidence cannot support.

The order is deliberate. Recommending well is a harder problem than deleting, and it is the one
worth getting right before anything is allowed to touch a mailbox.

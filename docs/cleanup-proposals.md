# Cleanup proposals

A proposal is InboxSweep's opinion about a sender, with the evidence behind it printed beside
it. It is advice. Nothing a proposal says can carry itself out.

## Facts and verdicts are separate

Every sender row and detail pane reports **facts** first. Each one is scoped to the **loaded
window**, meaning the messages actually fetched, never to the whole mailbox, and the interface
says so.

| Observation | Definition |
| --- | --- |
| Messages loaded | Count of loaded messages from this sender |
| Unread | How many carry Gmail's `UNREAD` label |
| Starred / Important | How many carry `STARRED` / `IMPORTANT` |
| Gmail categories | The union of Gmail's own category labels seen on the loaded messages. Gmail assigns these; InboxSweep only reports which turned up, which is why a sender can show more than one |
| `List-Unsubscribe` | How many loaded messages carried the header |
| Unsubscribe | What the sender's headers amount to: no option, details unclear, one-click, a page, or an email request. A reading, not an action. See [Unsubscribing](unsubscribe.md) |
| First / latest loaded | Oldest and newest received dates in the loaded window. The oldest is a floor on how far back the app has looked, not the sender's first-ever message |
| Recent subjects | Up to three subjects, newest first, for recognising the sender |
| Frequency | Mean gap between consecutive loaded messages |

No observation is combined into a score, a rank, or a recommendation. A safety test asserts
that `SenderSummary` has no property named for a judgement.

??? note "How frequency is calculated"

    Take the loaded messages from one sender that carry a usable date, call the count *n*, and
    take the span from the oldest to the newest. Frequency is `span / (n - 1)`, the mean interval
    between consecutive messages, rendered as "about one message every *X*".

    It is absent when *n* is below 2 or the span is zero, because a cadence needs at least one
    real interval to measure. Messages the normalizer could not date are excluded, so one undated
    message cannot report a sender as writing once every few thousand years.

    It is a mean over a window, not a schedule the sender keeps. Loading more messages can change
    it.

## How a proposal is calculated

The engine is **pure and has no clock**. The same loaded window always produces the same
proposals, with the same reasons in the same order.

### Step 1: protection runs first, and can only veto

Protection is decided before any bulk-mail evidence is counted, and no amount of that evidence
can unlock a cleanup suggestion for a sender that raised a protection signal. A protected sender
gets a warning with the matched evidence shown, not a quiet downgrade.

### Step 2: bulk-mail signals are counted

Eight independent observations, each a fact the mailbox stated rather than a conclusion:

| Signal | Fires when |
| --- | --- |
| High volume | The sender is above the message-count threshold in the loaded window |
| Promotions category | Gmail itself filed the mail under Promotions |
| List metadata | The messages carry `List-Unsubscribe` headers |
| Automated sender | The address itself looks like an automated one |
| Recurring cadence | The gaps between messages are regular |
| Mostly unread | Most of the loaded messages were never opened |
| No engagement markers | Nothing from this sender is starred or marked important |
| Wide window | The sender has been writing across most of the loaded span |

Each one that fires becomes a sentence you can read on the sender's detail pane.

### Step 3: a pattern is matched, or not

A named pattern (a newsletter, a promotional sender, a notification service) requires **three
specific signals to agree**, never one. A sender that matches no pattern but trips four signals
is still put forward for review on the count alone, and strength is the count of agreeing
signals translated into a named band.

A sender that matches none of that gets no proposal at all, which is the common case and is not
a failure.

## Explainable by construction

A proposal carries its reasons as data rather than rendering a sentence and hoping it matches.
`SenderCleanupProposal` holds the verdict; `ProposalReason` values hold the individual findings;
the view prints them. There is no path by which the badge and the explanation can disagree,
because the badge is derived from the same values the explanation lists.

!!! warning "This is not a classifier you should trust blindly"

    Protection is decided by matching **literal phrases in subject lines**. It will miss a bank
    whose subjects are opaque, and it will flag a newsletter about tax software. That is why
    every protection warning shows the evidence behind it, and why nothing a proposal says can
    execute.

    There is no model here, no training data, and no AI service. It is a keyword list and a set
    of counting rules, and it is documented as such so nobody mistakes it for more.

## Dry-run previews

A preview answers "what would this cleanup affect?" **Building one makes no request of any
kind.** It is a calculation over the window already in memory.

The planner offers a fixed set of cutoffs: keep the newest 5, or cut at 30 or 90 days. There is
no way to type an arbitrary one, though a saved plan's file format would carry one.

A preview shows, per sender, how many loaded messages the cutoff would reach, how many are
protected and therefore excluded, and what the remainder is. Plan counts and the messages behind
them come from **one pass**: the per-message classification the review screen renders is what
the counts are summed from, so a total can never sit above a list that does not add up to it.

## The loaded window is not your mailbox

Proposals describe the loaded window. Loading more messages can change a sender's proposal, and
a long-running newsletter contributes only its recent issues to a 250-message window. The
preview states which case applies.

The load bar chooses how much to read and from where: the Inbox, any of Gmail's four categories,
or All mail. Each load reads **one** scope, and changing it discards the loaded window and reads
the new one, because a window mixing two of them would make every count describe something
nobody could name.

Depth is capped. The default is the 250 most recent messages and the documented ceiling is
2,500. There is no "load everything", because a message costs a metadata request and an
unbounded load is a denial of service aimed at your own API quota.

## Reviewing the messages behind a proposal

Opening a sender lists the loaded messages behind its row: subject, date, read state, starred
and important state, categories, and whether the message carried an unsubscribe header. There is
no body to show, and no way to open one.

From a preview, **Review messages to archive…** opens the message review with the preview's
messages already ticked, minus anything protected. That is the only bridge between a
recommendation and a change, and all it does is write ticks into a checkbox column. See
[Archiving and undo](archive-and-undo.md#where-a-selection-comes-from).

## Saved plans

Your planning choices persist so a preview can be reopened rather than rebuilt. A saved plan
holds the cutoff, the senders it covered, and the exclusions you made.

A saved plan **cannot execute**. One naming "archive messages older than 30 days" reopens a
preview when restored, and that is all it can ever do. There is no run button, no scheduler, and
no code path from a stored plan to a mutation.

!!! note "A saved plan names senders"

    It is one of two places InboxSweep writes a list of who writes to you, the other being your
    [sender rules](rules.md#the-one-new-thing-on-disk). It lives in the app's sandbox container
    with `0600` permissions and is deleted when you disconnect.

## Why proposals are not executable

The separation is structural rather than a policy. Proposals are recomputed on every launch and
never persisted, so there is nowhere to store a verdict that could later be acted on; the
planner produces a description rather than a command; and the mutation boundary is reachable
only from a confirmation sheet that lists messages by subject and date.

`SafetyBoundaryTests` asserts that loading, previewing, saving a plan, restoring one, re-sorting,
and reloading reach the mutation boundary zero times.

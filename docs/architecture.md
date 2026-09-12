# Architecture

InboxSweep is a single macOS app target with no runtime dependencies. There is no server, no
database, and no third-party library. Everything below is in this repository.

## The layers

Dependencies point in one direction. Domain code imports no Gmail types and no Google
frameworks; the Gmail adapter is reachable only through protocols the domain owns.

```
UI            SwiftUI views                       InboxSweep/UI
  |
Application   InboxSessionModel, InboxSnapshot    InboxSweep/Application
  |
Domain        EmailAddress, MailMessage,          InboxSweep/Domain/Models
              SenderSummary, SenderAggregator,    InboxSweep/Domain/Aggregation
              MailMessageWindow
              CleanupPlanner, proposal engine     InboxSweep/Domain/Planning
                                                  InboxSweep/Domain/Proposals
              SenderRule and its matcher          InboxSweep/Domain/Rules
              List-Unsubscribe parsing            InboxSweep/Domain/Unsubscribe
  |
Boundaries    MailProvider, MailAccountAuthorizing,
              MailMessageFetching, MailProviderError,
              MailMessageArchiving, MailMutationError,
              MailUnsubscribing, InboxCacheStoring,
              MailMutationRecording, SenderRuleStoring
                                                  InboxSweep/Domain/Providers
                                                  InboxSweep/Domain/Persistence
  |
Adapters      GmailProvider, OAuth client,        InboxSweep/Providers/Gmail
              API client, normalizer,
              Keychain credential store
              File-backed cache, plan, mutation,  InboxSweep/Providers/Persistence
              and rule stores
              One-click unsubscribe client        InboxSweep/Providers/Unsubscribe
              SampleMailProvider (Debug only)     InboxSweep/Providers/Sample
```

## The seams

Four protocols are what make the whole adapter testable with no network and no Google account.

| Seam | What it abstracts | Why it exists |
| --- | --- | --- |
| `HTTPTransport` | Every HTTP request the Gmail adapter makes | A test can assert on the exact request, not on a mock of an intention |
| `WebAuthenticating` | `ASWebAuthenticationSession` | Sign-in can be faked, so the OAuth exchange is testable end to end |
| `InboxCacheStoring` | Persistence of the loaded window | Relaunch behaviour is testable without touching the file system, and the default implementation stores nothing |
| `MailMessageArchiving` | The mutation boundary | It is **optional**. A provider vends one only if it can write |

That last one is the important one. Read and write are different boundaries:
`MailMessageFetching` still has exactly one method and it fetches. "Can this thing change a
mailbox?" is answered by whether it vends an archiver, not by reading its implementation. The
synthetic mailbox has no code path to a mutation rather than a guard someone has to remember.

## Decisions worth knowing

### The domain model

- **`MailMessage` has no field for a message body.** Metadata-only is structural rather than a
  convention. A cache file cannot contain mail content even in principle, because there is
  nowhere to put it.
- **Read state is derived from labels**, so `isUnread` and the label set can never disagree.
- **Facts and verdicts are separate types.** `SenderSummary` carries counts and dates and no
  judgement; `SenderCleanupProposal` carries the judgement and the sentences behind it. A
  safety test asserts that no scoring leaks back down into the facts.
- **Malformed `From` headers cannot crash the app.** Parsing is total. Senders with no readable
  address collapse into a single anonymous group rather than fragmenting the list, and that
  group never borrows one of their display names.

### Reading

- **Pages merge by message ID, they do not append.** Gmail can list the same message on two
  consecutive pages; `MailMessageWindow` collapses those so no sender is double-counted.
- **Sender sorting is a total order.** Every sort ends in the sender's grouping key, so the
  dashboard never reshuffles between identical loads.
- **There is no unbounded load.** Every depth is finite and capped, because a message costs a
  metadata request and an unbounded "load everything" is a denial of service aimed at the
  user's own API quota.

### Recommending

- **The proposal engine is pure and has no clock.** The same loaded window always produces the
  same proposals, with the same reasons in the same order. Only the dry-run planner takes a
  date, and it is passed in.
- **Proposals are recomputed, never persisted.** A rules change takes effect on the next launch
  instead of leaving stale verdicts on screen. The cache record has nowhere to store one.
- **Protection runs before the cleanup rules and can only veto.** No amount of bulk-mail
  evidence unlocks a cleanup suggestion for a sender that raised a protection signal.
- **Plan counts and the messages behind them come from one pass.** The per-message
  classification the review screen renders *is* what the entry counts are summed from, so a
  total can never sit above a list that does not add up to it.

### Writing

- **The mutation vocabulary is two constants, not a parameter.** `GmailMutationRequest` can
  carry one of two literal bodies, so "add or remove `INBOX` on one named message" is the whole
  of what the app can express. A request that trashed a message or applied your own label is
  not something the type can be asked to build.
- **Nothing is claimed before Gmail confirms it.** Local state is reconciled from the labels on
  Gmail's *reply*, not from the ones the app asked for, so a failure needs no rollback and a
  success is never optimistic.
- **An archived message leaves the window without leaving memory.** Inbox membership is derived
  from labels by `MailboxScope.retains`, which is what lets undo restore a message to its
  original position instead of appending it, and what makes the next refresh agree.
- **A local write failure is not a remote failure.** If Gmail changes the mailbox and this Mac
  cannot record it, that is reported as a success with a caveat. The opposite would tell you
  your mail was untouched when it was not.

### Restoring

- **A failed restore is not the same as a first launch.** `MailRestoreOutcome` has three cases
  rather than two, so "nothing stored" and "the Keychain refused us" cannot produce the same
  silent signed-out screen. That distinction exists because its absence let a
  credential-persistence bug survive an entire development interval.

## What is stored, and where

Four files, all inside the app's own sandbox container, all deleted on disconnect.

| File | Holds | Page |
| --- | --- | --- |
| Cache | The loaded window: message metadata and derived sender summaries | [Privacy and security](privacy-and-security.md#what-is-stored-on-this-mac) |
| Saved plans | Your dry-run planning choices, including sender addresses | [Cleanup proposals](cleanup-proposals.md#saved-plans) |
| Mutation history | What was changed: operation, message IDs, outcome, undo state | [Activity](activity.md) |
| Sender rules | The addresses you authorized, and what each rule does | [Sender rules](rules.md#the-one-new-thing-on-disk) |

None of them holds a token. The refresh token is in the macOS Keychain; the access token is in
memory only.

## Repository layout

```
InboxSweep/                 App target
  App/                      Entry point, composition root, UI test harness
  Application/              Session state for the UI
  Domain/                   Provider-agnostic models, aggregation, boundaries
    Aggregation/            Sender grouping and the loaded window
    Models/                 Addresses, messages, labels, header decoding
    Persistence/            Cache and mutation-history protocols
    Planning/               The dry-run cleanup planner
    Proposals/              The proposal engine and sender protection
    Providers/              The boundary protocols
    Rules/                  Sender rules: the value, the matcher, the store protocol
    Unsubscribe/            List-Unsubscribe parsing and mechanism selection
  Providers/Gmail/          The Gmail adapter, and the only Gmail-aware code
  Providers/Networking/     The HTTPTransport seam
  Providers/Persistence/    On-disk cache, plan, mutation-record, and rule stores
  Providers/Sample/         The synthetic mailbox, Debug builds only
  Providers/Unsubscribe/    One-click client, redirect policy, URL opener
  UI/                       SwiftUI views
  Config/                   Your local OAuth client plist (gitignored)
InboxSweepTests/            Unit tests, fixtures, and test doubles
InboxSweepUITests/          UI tests against the synthetic mailbox
Scripts/                    Repository hygiene checks, run locally and in CI
docs/                       This site
```

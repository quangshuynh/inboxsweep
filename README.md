# InboxSweep

A privacy-conscious Gmail cleanup assistant for macOS.

**InboxSweep recommends; you authorize.** It reads your Gmail metadata, groups it by sender,
tells you which senders are probably worth cleaning up and why, and previews what a cleanup
*would* reach. It has no ability to delete, archive, label, move, or send mail.

> **Read-only.** InboxSweep requests a single Gmail permission that cannot modify a mailbox,
> and the app contains no code that writes to one. It can recommend and preview; it cannot act.
> See [Privacy posture](#privacy-posture).

<!-- Interval 3 · macOS · SwiftUI · Swift 6 -->

## What the app does

- Connects a Google account with OAuth 2.0 (authorization code + PKCE, no client secret).
- Requests exactly one scope: `gmail.metadata` — headers, labels, and dates. Not bodies.
- Fetches a bounded window of message metadata (250 messages by default) with bounded
  concurrency, cancellation support, and pagination.
- Normalizes Gmail's responses into app-owned domain models.
- Groups messages by sender and shows per-sender counts in a native macOS dashboard.
- Caches the loaded window locally, so a relaunch costs no Gmail quota and no waiting. The
  header says how old the shown window is; disconnecting deletes the file.
- **Proposes what to do about each sender, with its reasons** — likely newsletter, likely
  promotional clutter, likely recurring notification, possible cleanup candidate, review, or
  keep — from deterministic rules over metadata. No AI.
- **Protects mail that looks worth keeping** — starred, Gmail-Important, personal
  correspondence, and subject lines suggesting security, financial, receipt, travel,
  government, employment, or healthcare topics — and downgrades or withholds a suggestion
  rather than proposing cleanup for it.
- **Previews a cleanup without performing one.** Select senders, choose a conceptual action,
  and see how many loaded messages it would affect, how many would stay put, and exactly why
  each retained message was retained.
- Handles signed-out, restoring, connecting, loading, loaded, empty, and error states.
- Runs entirely against synthetic data when no Google account is configured, so the whole app
  can be developed and tested offline.

**[Docs/CleanupProposals.md](Docs/CleanupProposals.md) is the full account** of how proposals
are calculated, what the protection rules are, what a dry run does and does not tell you, and
why this is still read-only. Read it before trusting a suggestion.

## What the app deliberately does not do

None of the following is implemented, and the UI does not pretend otherwise:

| Not implemented | |
| --- | --- |
| Delete, trash, or archive | Mark as read, star, or label |
| Unsubscribe (of any kind) | Executing any cleanup at all |
| AI classification of any message | Cleanup rules or scheduling |
| Background monitoring or notifications | Storage-savings estimates |
| Analytics or telemetry | CI, badges, or releases |

Cleanup is **proposed and previewed only**. There is no button that carries one out, no Gmail
permission that would allow it, and no code path that tries. `List-Unsubscribe` headers are
read as evidence that a sender is a mailing list; the address they name is never contacted.

## Architecture

Dependencies point in one direction. Domain code imports no Gmail types and no Google
frameworks; the Gmail adapter is reachable only through protocols the domain owns.

```
UI            SwiftUI views                      InboxSweep/UI
  ↓
Application   InboxSessionModel, InboxSnapshot   InboxSweep/Application
  ↓
Domain        EmailAddress, MailMessage,         InboxSweep/Domain/Models
              SenderSummary, SenderAggregator    InboxSweep/Domain/Aggregation
              SenderEvidence, SenderProtection,  InboxSweep/Domain/Proposals
              CleanupProposalEngine
              CleanupPlanner, CleanupPlan        InboxSweep/Domain/Planning
  ↓
Boundaries    MailProvider, MailAccountAuthorizing,
              MailMessageFetching, MailProviderError
                                                 InboxSweep/Domain/Providers
  ↓
Adapters      GmailProvider + OAuth, API client, InboxSweep/Providers/Gmail
              normalizer, keychain store
              FileInboxCacheStore                InboxSweep/Providers/Persistence
              SampleMailProvider (debug only)    InboxSweep/Providers/Sample
```

Two seams make the whole adapter testable without a network or a Google account:

- **`HTTPTransport`** — every HTTP request the adapter makes goes through it.
- **`WebAuthenticating`** — wraps `ASWebAuthenticationSession`, so sign-in can be faked.

Notable decisions:

- **`MailMessage` has no field for a message body.** Metadata-only is structural, not a
  convention someone has to remember.
- **Read state is derived from labels**, so `isUnread` and the label set can never disagree.
- **Sender sorting is a total order.** Every sort ends in the sender's grouping key, so the
  dashboard never reshuffles between identical loads. This is tested.
- **Malformed `From` headers cannot crash the app.** Parsing is total; senders with no
  readable address collapse into a single anonymous "Unknown sender" group rather than
  fragmenting the list, and that group never borrows one of their display names.
- **Facts and verdicts are separate types.** `SenderSummary` carries counts and dates and no
  judgement; `SenderCleanupProposal` carries the judgement and the sentences behind it. The
  dashboard can therefore always be read without the verdict beside it, and a safety test
  asserts no scoring leaks back down into the facts.
- **The proposal engine is pure and has no clock.** The same loaded window always produces the
  same proposals, with the same reasons in the same order. Only the dry-run planner takes a
  date, and it is passed in.
- **Proposals are recomputed, never persisted.** A rules change takes effect on the next launch
  instead of leaving stale verdicts on screen. The cache record has nowhere to store one.
- **Protection runs before the cleanup rules and can only veto.** No amount of bulk-mail
  evidence unlocks a cleanup suggestion for a sender that raised a protection signal.

## Gmail permission

InboxSweep requests one scope:

```
https://www.googleapis.com/auth/gmail.metadata
```

It grants read access to message headers, labels, and dates — **not** message bodies or
attachments. It is narrower than the more common `gmail.readonly`, which would also hand the
app every message body.

The app never requests `gmail.modify`, `gmail.send`, `gmail.compose`, `gmail.insert`,
`gmail.labels`, `gmail.settings.*`, or `https://mail.google.com/`. `SafetyBoundaryTests`
asserts this; that every Gmail API request the app can construct is a `GET`; that no such
request's path reaches one of Gmail's mutating operations (`modify`, `trash`, `batchDelete`,
`send`, `settings`, and the rest); and that building a cleanup preview issues no provider call
and sends no HTTP request at all.

One practical consequence of the narrower scope: Gmail rejects search queries (`q=`) under
`gmail.metadata`. The fetch layer works within that limit rather than widening the scope.

## Getting started

**Requirements:** macOS 26.5+, Xcode 26.6+.

```bash
git clone <this repo>
cd InboxSweep
open InboxSweep.xcodeproj
```

The app runs without any Google configuration. The signed-out screen will explain that
sign-in is not set up, and in a Debug build an **Explore with sample data** button opens the
dashboard on a synthetic mailbox.

To connect a real account, follow **[Docs/OAuthSetup.md](Docs/OAuthSetup.md)**.

### Build

```bash
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep -configuration Debug -destination 'platform=macOS' build
```

### Test

```bash
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep -destination 'platform=macOS' test
```

No test requires a Google account, a network connection, or real mailbox data. Fixtures use
RFC 2606 reserved domains (`example.com`, `example.org`, `example.net`) throughout.

To run only the unit tests:

```bash
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep -destination 'platform=macOS' test -only-testing:InboxSweepTests
```

## Privacy posture

Claims below describe what this version actually does. Nothing more is implied.

- **Read-only access.** The one scope requested cannot change a mailbox, and the app contains
  no code path that writes to one.
- **No message is altered, moved, or deleted.** There is no feature to do so. The cleanup
  planner produces a description of what an action *would* reach; building one makes no
  request of any kind, and there is no control anywhere that carries one out.
- **Metadata only.** Message requests use `format=metadata` with four named headers (`From`,
  `Subject`, `Date`, `List-Unsubscribe`). Bodies and attachments are never requested and there
  is nowhere in the domain model to put them.
- **Local by default.** Message metadata lives in memory while the app is open and in one
  cache file inside InboxSweep's own container, so a relaunch does not re-read your inbox.
  Disconnecting deletes that file. The networking layer uses an ephemeral `URLSession`, so
  responses are not written to an on-disk URL cache. InboxSweep sends your mail to no server
  other than Google's own API.
- **Suggestions are computed on this Mac, from metadata already fetched.** No sender, subject,
  or count is sent anywhere to produce a proposal, and no proposal is written to disk — they
  are recomputed from the cached metadata on every launch.
- **No AI.** No message, header, or subject is sent to any AI service.
- **No analytics, no telemetry, no crash reporting.** There is no third-party runtime
  dependency of any kind.
- **Credentials.** Your Google password is typed into Google's own sign-in window
  (`ASWebAuthenticationSession`, with an ephemeral browser session); InboxSweep never sees it.
  The refresh token is stored in the macOS Keychain. Access tokens are held in memory only.
  Signing out asks Google to revoke the grant and deletes the Keychain item.
- **Nothing secret is committed.** The OAuth client is a public iOS/macOS client with no
  secret; the client ID is supplied at runtime and its path is gitignored.

What is *not* claimed: InboxSweep does not encrypt anything itself beyond what the Keychain
and TLS provide, has not been independently audited, and makes no anonymity guarantees.

## Known limitations

- The default window is the 250 most recent inbox messages, so all counts describe *what has
  been loaded*, not the whole mailbox. The UI says "Messages loaded" and shows how far back
  the window reaches for exactly this reason. **Load more messages** extends it a page at a
  time.
- The dashboard sorts through a toolbar picker; the table's column headers are not clickable.
- Only the inbox is read. `MailboxScope.allMail` exists at the boundary but no UI selects it.
- Gmail label *names* for custom labels are not resolved; unknown labels are carried through
  by their provider-side identifier.
- A `gmail.metadata` OAuth client stays in Google's "Testing" mode without verification, so
  only accounts listed as test users can sign in during development.
- The macOS deployment target inherited from the project template is 26.5, which is unusually
  high for a shipping app. Nothing in the code requires it.
- **Proposals are only as good as a keyword list.** Protection is decided by matching literal
  phrases in subject lines, so it will miss a bank whose subjects are opaque and will flag a
  newsletter about tax software. Every protection warning shows the evidence behind it for
  exactly this reason. See [Docs/CleanupProposals.md](Docs/CleanupProposals.md).
- **Proposals describe the loaded window, not the mailbox.** Loading more messages can change
  a sender's proposal, and a long-running newsletter contributes only its recent issues to a
  250-message window. The dry-run preview states which case applies.
- The dry-run planner offers a fixed set of cutoffs (keep newest 5; 30 and 90 days). There is
  no way to type an arbitrary one.
- A previewed plan is not saved. Closing the sheet discards the chosen actions.
- The Copy Bundle Resources build phase still contains the target's `Info.plist`, which
  produces one project-level build warning. It predates this interval and is untouched.

## Repository layout

```
InboxSweep/               App target
  App/                    Entry point and composition root
  Domain/Models/          Provider-agnostic mail models
  Domain/Aggregation/     Grouping messages by sender
  Domain/Proposals/       Evidence, protection rules, the proposal engine
  Domain/Planning/        Dry-run cleanup planner
  Domain/Providers/       Provider boundaries
  Domain/Persistence/     Cache contract
  Application/            Session state for the UI
  Providers/Gmail/        Gmail adapter (the only Gmail-aware code)
  Providers/Persistence/  Local cache store and its file format
  Providers/Sample/       Synthetic mailbox, debug builds only
  Providers/Networking/   HTTPTransport seam
  UI/                     SwiftUI views
  Config/                 Your local OAuth client plist (gitignored)
InboxSweepTests/          Unit tests, fixtures, and test doubles
InboxSweepUITests/        Launch, dashboard, and dry-run UI tests
Docs/                     OAuth setup guide, plist template, proposal rules
```

## Licence

See [LICENSE](LICENSE).

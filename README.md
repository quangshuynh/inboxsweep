# InboxSweep

A privacy-conscious Gmail cleanup assistant for macOS.

**InboxSweep recommends; you authorize.** It reads your Gmail metadata, groups it by sender,
says which senders look worth cleaning up and why, and shows what a cleanup *would* affect. The
one change it can make is archiving the **messages you tick and confirm as a list** — and undoing
them. It cannot act on a sender, run a cleanup plan, or delete anything.

> **One kind of write, and you press it.** Archiving removes the `INBOX` label from each message
> you named, one request at a time. There is no sender-level action, no cross-sender cleanup, and
> no way for a recommendation to carry itself out — the closest it gets is ticking boxes you then
> check. See [Archiving](#archiving-messages) and [Privacy posture](#privacy-posture).

<!-- macOS · SwiftUI · Swift 6 -->

## What it does

- Connects a Google account with OAuth 2.0 (authorization code + PKCE, no client secret).
- Requests two scopes: `gmail.metadata` to read headers, labels, and dates — not bodies — and
  `gmail.modify`, the narrowest permission Google publishes that can archive.
- Fetches a bounded window of message metadata with bounded concurrency, cancellation support,
  and pagination — **250 messages by default, up to a documented ceiling of 2,500** — from the
  Inbox, any of Gmail's four categories, or All mail.
- Normalizes Gmail's responses into app-owned domain models.
- Groups messages by sender and shows per-sender counts in a native macOS dashboard.
- Reports **sender observations** — Gmail's own categories, `List-Unsubscribe` presence,
  read/unread counts, the span of loaded mail, and how often the sender arrives.
- Opens a sender to list the loaded messages behind its row: subject, date, read state,
  starred and important state, categories, and whether the message carried an unsubscribe
  header.
- **Saves the loaded window to this Mac**, so relaunching restores the dashboard without
  re-reading the mailbox, and says on screen when what you are looking at came from disk.
- **Archives the messages you tick and confirm as a list**, after a confirmation naming every
  one of them by subject and date — one Gmail request per message, each with its own outcome, so
  a run where some are refused reports "8 archived, 2 failed" rather than "failed".
- **Offers Undo that survives quitting the app**, restoring exactly the messages that archive
  confirmed. A real Gmail request, not a local correction.
- Keeps a small, bounded local record of what it changed, holding message IDs and no mail.
- Handles signed-out, restoring, connecting, loading, loaded, empty, and error states.
- Runs entirely against synthetic data when no Google account is configured, so the whole app
  can be developed and tested offline.

## What it deliberately does not do

None of the following is implemented, and the UI does not pretend otherwise:

| Not implemented | |
| --- | --- |
| Delete, trash, or permanently remove | Mark as read, star, or label |
| Unsubscribe (of any kind) | Archive a sender in one click, or across senders |
| AI classification of any message | Executing a cleanup plan |
| Background monitoring or notifications | Automatic or scheduled archiving |
| Analytics or telemetry | CI, badges, or releases |

Archiving is the one exception, and it is deliberately narrow: **messages you named individually**,
frozen into a list you confirm, sent one request at a time, undoable. There is no control anywhere
that archives a sender, a plan, or anything you did not tick, and no path from a proposal or a
saved plan to a mutation. A cleanup preview can *fill in* a selection for you to check and edit;
it cannot carry itself out.

`List-Unsubscribe` headers are *recorded* as an observation. Nothing in this version reads
that flag to decide anything, and the app never contacts an unsubscribe URL.

## Architecture

Dependencies point in one direction. Domain code imports no Gmail types and no Google
frameworks; the Gmail adapter is reachable only through protocols the domain owns.

```
UI            SwiftUI views                      InboxSweep/UI
  ↓
Application   InboxSessionModel, InboxSnapshot   InboxSweep/Application
  ↓
Domain        EmailAddress, MailMessage,         InboxSweep/Domain/Models
              SenderSummary, SenderAggregator,   InboxSweep/Domain/Aggregation
              MailMessageWindow
  ↓
Boundaries    MailProvider, MailAccountAuthorizing,
              MailMessageFetching, MailProviderError,
              MailMessageArchiving, MailMutationError,
              InboxCacheStoring, CachedInbox,
              MailMutationRecording              InboxSweep/Domain/Providers
                                                 InboxSweep/Domain/Persistence
  ↓
Adapters      GmailProvider + OAuth, API client, InboxSweep/Providers/Gmail
              normalizer, keychain store
              FileInboxCacheStore + cache DTOs   InboxSweep/Providers/Persistence
              SampleMailProvider (debug only)    InboxSweep/Providers/Sample
```

Three seams make the whole adapter testable without a network or a Google account:

- **`HTTPTransport`** — every HTTP request the adapter makes goes through it.
- **`WebAuthenticating`** — wraps `ASWebAuthenticationSession`, so sign-in can be faked.
- **`InboxCacheStoring`** — persistence is a protocol the domain owns, so the session's
  relaunch behaviour is testable without touching the file system, and the default
  implementation stores nothing.
- **`MailMessageArchiving`** — the mutation boundary, separate from the read boundary and
  *optional*. A provider vends one only if it can write, so the synthetic mailbox has no code
  path to a mutation rather than a guard someone has to remember.

Notable decisions:

- **`MailMessage` has no field for a message body.** Metadata-only is structural, not a
  convention someone has to remember — and it means a cache file cannot contain mail content
  even in principle.
- **Read state is derived from labels**, so `isUnread` and the label set can never disagree.
- **Sender sorting is a total order.** Every sort ends in the sender's grouping key, so the
  dashboard never reshuffles between identical loads. This is tested.
- **Pages merge by message ID, they do not append.** Gmail can list the same message on two
  consecutive pages; `MailMessageWindow` collapses those so no sender is double-counted.
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
- **A failed restore is not the same as a first launch.** `MailRestoreOutcome` has three cases
  rather than two, so "nothing stored" and "the Keychain refused us" cannot produce the same
  silent signed-out screen — which is how a credential-persistence bug survived a whole
  interval. See [Docs/SessionRestore.md](Docs/SessionRestore.md).
- **Plan counts and the messages behind them come from one pass.** The per-message
  classification the review screen renders *is* what the entry counts are summed from, so a
  total can never sit above a list that does not add up to it.
- **There is no unbounded load.** Every depth is finite and capped, because a message costs a
  metadata request and an unbounded "load everything" is a denial of service aimed at the
  user's own quota.
- **Reading and writing are different boundaries.** `MailMessageFetching` still has exactly one
  method and it fetches. Archiving lives on its own optional protocol, so "can this thing change
  a mailbox?" is answered by whether it vends an archiver, not by reading its implementation.
- **The mutation vocabulary is two constants, not a parameter.** `GmailMutationRequest` can
  carry one of two literal bodies, so "add or remove `INBOX` on one named message" is the whole
  of what the app can express. A request that trashed a message or applied your own label is not
  something the type can be asked to build.
- **Nothing is claimed before Gmail confirms it.** Local state is reconciled from the labels on
  Gmail's *reply*, not from the ones the app asked for, so a failure needs no rollback and a
  success is never optimistic.
- **An archived message leaves the window without leaving memory.** Inbox membership is derived
  from labels by `MailboxScope.retains`, which is what lets undo restore the message to its
  original position instead of appending it, and what makes the next refresh agree.
- **A local write failure is not a remote failure.** If Gmail changes the mailbox and this Mac
  cannot record it, that is reported as a success with a caveat. The opposite would tell the
  user their mail was untouched when it was not.

## Gmail permissions

InboxSweep requests two scopes:

```
https://www.googleapis.com/auth/gmail.metadata   read headers, labels, dates
https://www.googleapis.com/auth/gmail.modify     change which labels a message carries
```

`gmail.metadata` is narrower than the more common `gmail.readonly`, which would also hand the
app every message body.

`gmail.modify` is what archiving needs, and it is **broader than what the app does with it** —
it would also permit trashing, marking read, applying arbitrary labels, and reading bodies.
Google publishes no narrower permission that can remove the `INBOX` label: `gmail.labels`
governs label *definitions*, not applying them to a message. The alternative is not a smaller
scope; it is not having an archive feature. Since the permission cannot be narrowed, the limit
is in the code, and the signed-out screen says so before you are sent to Google rather than
letting the consent screen contradict the app.

The app never requests `https://mail.google.com/` — the full-access scope, and the only one that
permits **permanent deletion** — nor `gmail.send`, `gmail.compose`, `gmail.insert`,
`gmail.labels`, `gmail.settings.*`, or contacts.

`SafetyBoundaryTests` asserts all of the above, and that:

- every *read* request the app can construct is a `GET` reaching no mutating path;
- there are exactly **two** mutating requests, both `POST`s to
  `users/me/messages/{id}/modify`, never to a thread or batch endpoint;
- their bodies name `INBOX` and no other label, and carry one instruction each;
- a message identifier is percent-encoded into a single path segment and cannot redirect a
  request;
- loading, previewing, saving a plan, restoring one, re-sorting, and reloading all reach the
  mutation boundary **zero** times;
- a provider is read-only unless it deliberately vends an archiver.

One practical consequence of `gmail.metadata`: Gmail rejects search queries (`q=`) under it.
The fetch layer works within that limit, and still requests `format=metadata` with four named
headers even though `gmail.modify` would now permit bodies.

## Sender observations

Each sender row and detail pane reports facts, not judgements. Every one is scoped to the
**loaded window** — the messages actually fetched — never to the whole mailbox, and the UI
says so.

| Observation | Definition |
| --- | --- |
| Messages loaded | Count of loaded messages from this sender. |
| Unread | How many of those carry Gmail's `UNREAD` label. |
| Starred / Important | How many carry `STARRED` / `IMPORTANT`. |
| Gmail categories | The union of Gmail's own category labels (Promotions, Social, Updates, Forums, Personal) seen on the loaded messages. Gmail assigns these; InboxSweep only reports which turned up, which is why a sender can show more than one. |
| `List-Unsubscribe` | How many loaded messages carried the header. Reported, never acted on. |
| First / latest loaded | Oldest and newest received dates in the loaded window. The oldest is a floor on how far back the app has looked, not the sender's first-ever message. |
| Recent subjects | Up to three subjects, newest first, for recognising the sender. |
| Frequency | Mean gap between consecutive loaded messages. |

**The frequency rule.** Take the loaded messages from one sender that carry a usable date,
call the count *n*, and take the span from the oldest to the newest. Frequency is
`span ÷ (n − 1)` — the mean interval between consecutive messages — rendered as "about one
message every *X*". It is `nil`, and nothing is shown, when *n* < 2 or the span is zero,
because a cadence needs at least one real interval to measure. Messages the normalizer could
not date are excluded, so one undated message cannot report a sender as writing once every few
thousand years. It is a mean over a window, not a schedule the sender keeps: loading more
messages can change it. `SenderObservationTests` covers each of these cases.

No observation is combined into a score, a rank, or a recommendation. `SafetyBoundaryTests`
asserts that `SenderSummary` has no property named for a judgement.

## Archiving messages

The app's only write. Full detail in **[Docs/Archiving.md](Docs/Archiving.md)**.

In Gmail a message is in the Inbox exactly when it carries the `INBOX` label, so archiving one
*is* removing that label:

```
POST /gmail/v1/users/me/messages/{id}/modify   {"removeLabelIds":["INBOX"]}
POST /gmail/v1/users/me/messages/{id}/modify   {"addLabelIds":["INBOX"]}     # undo
```

Those two are the complete set of mutating requests the app can build.

**The flow.** Open a sender → **Review…** → tick messages (individually, **Select all shown**, or
**Fill from preview** then edit) → **Archive N messages…** → a confirmation listing every message
by subject and received date, saying they will be removed from your Inbox and not deleted →
confirm → one request per message → a per-message result, with **Undo** beside it.

**Sender-level review.** For a sender with forty messages, **Review messages to archive…** — in
the sender inspector and on a sender's dry-run row — opens that same review with the current
preview's messages already ticked, minus anything protected. It is not *Archive sender*: it opens
a screen and changes nothing. You still inspect the list, edit it in both directions, open a
confirmation, and press the button, and the confirmation says that only the messages listed are
changed and that future mail from that sender is unaffected. There is no whole-sender operation,
no rule, and no schedule anywhere behind it.

## Activity

What InboxSweep has changed in this mailbox, newest first, read from the same local transaction
records that make undo survive a relaunch. Full detail in **[Docs/Activity.md](Docs/Activity.md)**.

It is a reader: opening it, listing it, and opening a row send nothing to Gmail. The only control
on it that can reach a mailbox is the existing **Undo**, offered on the one transaction the app
already considers undoable — being listed never makes an older change actionable.

Each entry says what was attempted, what Gmail confirmed, what did not go through, and where its
undo stands. Partial operations stay partial: *"Archived 8 of 10 messages"* does not become
*"Archived 8 messages"* later, and putting some of them back does not turn a complete archive
into a failed one.

It holds counts and message identifiers — **no subjects, no senders, no mail**. Where the loaded
window still describes the messages, the detail view resolves them dynamically; where it does
not, it says so and the counts stand on their own. A row reads *"Archived 15 messages from one
sender"* only when the cache can describe every message it names and they agree — derived at draw
time, with nothing stored to make it possible, and never a claim that the sender itself was
archived or that its future mail is affected.

Reachable from the toolbar and from a link in the dashboard footer, so the question does not
depend on a toolbar being easy to get at.

> **Activity is what InboxSweep changed, not everything that happened in Gmail.** Archive a
> message in Gmail itself and InboxSweep reconciles its view on the next reload without writing
> an entry claiming it did so. The history keeps the 100 most recent changes per account, and
> signing out deletes them.

| | |
| --- | --- |
| **Scope** | The messages you ticked. Not their threads, not their sender, nothing else. |
| **Effect** | `INBOX` removed. Read state, star, importance, and Gmail category untouched. |
| **Execution** | One `messages.modify` per message, strictly one at a time. Not `batchModify`, which reports no per-message result and so could not be reconciled against. |
| **Frozen set** | The confirmation shows an immutable snapshot carrying the account, sender, loaded scope, and exact messages. If the account, permission, scope, sender, window, or Inbox membership stops matching — or the confirmation has already run — the operation is refused whole and re-reviewed, never narrowed and never re-derived from fresher planner output. |
| **Partial failure** | Per-message outcomes: archived, failed, not sent. Successes are never rolled back because something else failed; failures stay in your Inbox locally and remotely. |
| **Protection** | No convenience action ever ticks a protected message. You can tick one yourself, and the confirmation says so. |
| **Undo** | A real Gmail request per message, restoring only what that transaction confirmed. Can itself partly fail, and then narrows to what is still archived. |
| **Undo lifetime** | **Survives dismissing the sheet, reloading, and quitting the app.** One undoable archive per account: a new one supersedes the last. Ends on undo, supersede, or disconnect. No timer. |
| **In flight** | **Stop** stops before the next message — the request already sent cannot be recalled, and the sheet says so. A repeated confirmation of the same frozen set is refused by the session, not only by a disabled button. |
| **Local state** | Reconciled per message from the labels on Gmail's reply, only after it confirms. Summaries, proposals, protection, plan membership, and the cache all recompute. |
| **Transaction** | Operation, confirmed message IDs, selected count, account, timestamp, undo state. No subject, no sender, no body. Bounded to 50, deleted on disconnect. |

**If you signed in before archiving existed**, your read-only grant keeps working and is not
treated as broken. The Archive control becomes **Enable archiving…**, which asks for the extra
permission and nothing else; declining leaves the session exactly as it was. Granting it
persists the widened scope, keeping the refresh token Google does not reissue.

**Recommendations still cannot execute.** Proposals, dry-run previews, and saved plans are
advisory. A saved plan naming "archive messages older than 30 days" reopens a preview when
restored, and that is all it can ever do. **Fill from preview** and **Review messages to
archive…** are the only bridges between a recommendation and a change, and both write ticks into
a checkbox column — you still read the list, edit it, open a confirmation, and press the button
yourself.

## Local persistence

The loaded window is written to a JSON file inside the app's own sandbox container so a
relaunch restores the dashboard instead of re-reading the mailbox.

**Where:** `~/Library/Containers/quang.InboxSweep/Data/Library/Application Support/InboxSweep/Cache/`,
one file named after a SHA-256 digest of the account address, written atomically with
`0600` permissions and excluded from backups.

**What is stored** — message metadata only:

| Stored | Not stored |
| --- | --- |
| Provider message and thread IDs | Message bodies |
| Sender name and address | Attachments or their contents |
| Subject line | Access tokens |
| Received date | Refresh tokens (those stay in the Keychain) |
| Labels, including Gmail's categories | Raw Gmail API responses |
| Whether a `List-Unsubscribe` header was present | Anything else the API returned |
| The derived sender summaries and the next-page cursor | |

**How it behaves:**

- **One account at a time.** The file is keyed by account, a load refuses to hand back a
  window whose stored address does not match, and a save deletes any other account's file. A
  second account can never show the first one's mail.
- **Restored windows are labelled.** The dashboard header says the window came from this Mac
  and when it was read, with **Reload** as the way to ask Gmail for current mail. Adding a
  page to a restored window does not make the older pages look freshly read.
- **Pagination survives a relaunch.** The next-page cursor is stored, so **Load more
  messages** continues from where the last launch stopped rather than restarting the fetch.
- **Merging is deterministic.** Pages merge by provider message ID: a message keeps the
  position it first appeared at, and takes the content of the most recent copy seen. A file
  that somehow holds a message twice is collapsed on the way in.
- **Derived data is checked, not trusted.** Stored sender summaries are used only when they
  still add up to the stored messages; otherwise they are rebuilt from them.
- **Invalidation is safe.** A file with an unrecognised schema version, or one that is
  truncated, corrupt, or written for another account, is discarded and the mailbox is fetched
  as if nothing had been stored. Nothing here throws: a cache that cannot be read is a
  refetch, and a cache that cannot be written is a refetch next launch.
- **Disconnecting deletes it.** Signing out revokes the Google grant, removes the Keychain
  item, and removes the file.
- **Sample data is never written.** The synthetic mailbox runs on the no-op cache.

The `Reload` path replaces the stored window; it does not merge into it.

## Getting started

**Requirements:** macOS 26.5+, Xcode 26.6+.

```bash
git clone https://github.com/quangshuynh/InboxSweep.git
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

```bash
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep -configuration Release -destination 'platform=macOS' build
```

### Test

```bash
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep -destination 'platform=macOS' test
```

The unit tests are hosted by `InboxSweep.app`, so `KeychainCredentialStoreTests` exercises the
real `SecItem*` path with the app's own bundle identifier and entitlements. It writes only
synthetic credentials under a test-only service name and deletes them afterwards.

### Check that a sign-in survives a relaunch

A launch argument writes a synthetic Keychain marker, reports what it found, and exits — so
cross-launch persistence can be checked without a Google password:

```bash
InboxSweep.app/Contents/MacOS/InboxSweep --keychain-selfcheck
```

Run it twice against one build; the second run should say `restored`.
`--keychain-selfcheck-reset` removes the marker.

macOS has two keychains and the app falls back between them silently, so a successful save does
not say which one it used. Two more arguments answer that:

```bash
InboxSweep.app/Contents/MacOS/InboxSweep --keychain-probe     # each keychain, no fallback
InboxSweep.app/Contents/MacOS/InboxSweep --keychain-backend   # where the real credential is
```

All four work in Release as well as Debug — the signed Release app is the build whose Keychain
behaviour most needs measuring — and all four are inert without their launch argument, reach no
UI, and print no token. Measured results and the signing configuration behind them are in
[Docs/ReleaseVerification.md](Docs/ReleaseVerification.md); the design is in
[Docs/SessionRestore.md](Docs/SessionRestore.md).

No test requires a Google account, a network connection, or real mailbox data. Fixtures use
RFC 2606 reserved domains (`example.com`, `example.org`, `example.net`) throughout, and the
persistence tests write to a temporary directory rather than to your own container.

To run only the unit tests:

```bash
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep -destination 'platform=macOS' test -only-testing:InboxSweepTests
```

## Privacy posture

Claims below describe what this version actually does. Nothing more is implied.

- **One kind of write, and you confirm each one.** InboxSweep can remove the `INBOX` label from
  a message you selected, and put it back. Those two requests are the complete set of mutations
  the app can construct — a set of twelve is twelve of the first, never a batch request.
- **No message is deleted, trashed, marked, labelled, or sent.** There is no feature to do any
  of it, and no scope that would permit permanent deletion.
- **Nothing acts on its own, or on anything you did not name.** There is no archive-sender,
  archive-all, cross-sender, execute-plan, scheduled, or background operation. The cleanup planner
  produces a description of what an action *would* reach; building one makes no request of any
  kind, and the only thing that description can do is pre-tick checkboxes you then inspect, edit,
  and confirm yourself.
- **Metadata only.** Message requests use `format=metadata` with four named headers (`From`,
  `Subject`, `Date`, `List-Unsubscribe`). Bodies and attachments are never requested — even
  though `gmail.modify` would now permit them — and there is nowhere in the domain model to put
  them.
- **A local record of what was changed.** One bounded file holds an operation, a message ID, an
  account, a timestamp, and an outcome per mutation. No mail. It is deleted on disconnect.
- **Local by default.** Message metadata lives in memory while the app runs and in one file
  inside the app's own sandbox container between launches — see
  [Local persistence](#local-persistence) for exactly what that file holds. The networking
  layer uses an ephemeral `URLSession`, so responses are not written to an on-disk URL cache.
  InboxSweep sends your mail to no server other than Google's own API.
- **No AI.** No message, header, or subject is sent to any AI service.
- **No analytics, no telemetry, no crash reporting.** There is no third-party runtime
  dependency of any kind.
- **Credentials.** Your Google password is typed into Google's own sign-in window
  (`ASWebAuthenticationSession`, with an ephemeral browser session); InboxSweep never sees it.
  The refresh token is stored in the macOS Keychain. Access tokens are held in memory only and
  are never written to the cache. Signing out asks Google to revoke the grant, deletes the
  Keychain item, and deletes the cache file.
- **Nothing secret is committed.** The OAuth client is a public iOS/macOS client with no
  secret; the client ID is supplied at runtime and its path is gitignored.

What is *not* claimed: the cache file is protected by the app sandbox, file permissions, and
whatever full-disk encryption the Mac has — InboxSweep does not encrypt it itself. The app has
not been independently audited and makes no anonymity guarantees.

## Known limitations

- The default window is the 250 most recent inbox messages, so all counts describe *what has
  been loaded*, not the whole mailbox. The UI says "Messages loaded" and shows how far back
  the window reaches for exactly this reason. **Load more messages** extends it a page at a
  time, and the extended window is what gets stored.
- A restored window is as old as its label says. InboxSweep never refreshes it on its own —
  there is no background monitoring — so **Reload** is the only thing that fetches current
  mail.
- Sender observations describe the loaded window only. Loading more messages can change a
  sender's frequency, category set, and unsubscribe count, and it is meant to.
- The cache is not migrated between schema versions. A version bump discards the stored
  window and the next launch fetches it again.
- The dashboard sorts through a toolbar picker; the table's column headers are not clickable.
- Sender detail lists the loaded messages but cannot open one: there is no body to show.
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
  no way to type an arbitrary one, though a saved plan's file format would carry one.
- The message review is per sender. There is no way to see every loaded message at once.
- **Archiving is per sender and explicitly selected, by design.** There is no sender-level
  one-click archive, no cross-sender cleanup, and no way to carry out a previewed plan. A large
  cleanup means ticking the messages — helped by **Fill from preview** and by **Review messages
  to archive…**, both of which only tick boxes — and confirming the list, which is the point
  rather than an oversight.
- **Sender-level review preselects from the loaded window only.** A sender with four hundred
  messages of which 250 are loaded gets candidates from the 250. Loading more and reopening the
  review is the way to reach the rest, and the screen says which window its counts describe.
- **A large set takes as long as it takes.** Messages go out one request at a time, so a set of
  several hundred is a visible wait. The alternative, `batchModify`, reports no per-message
  result and was rejected for that reason rather than for performance.
- **`gmail.modify` grants more than the app uses.** Google publishes nothing narrower that can
  archive, so the restraint is enforced by the code and its tests rather than by the permission.
  A user auditing the grant in their Google Account will see a broad permission; the app's
  limits are not visible from there.
- **Only the most recent archive is undoable, per account.** Archiving again supersedes the
  previous offer — the superseded transaction stays in the file as history, but there is no undo
  stack and no history UI. Once an offer is gone, those messages are in All Mail and moving them
  back is a Gmail operation.
- The mutation record is not surfaced in the UI. It is read by the session and kept for undo and
  local correctness; there is no screen that lists it yet.
- Archiving is message-level, so a conversation whose other messages are still in the Inbox
  stays in the Inbox. That matches Gmail's own behaviour but can surprise anyone expecting a
  thread to disappear.
- A saved plan holds sender addresses on disk in the app's container. It is deleted on
  disconnect, but it is the one place a list of who writes to you is written unencrypted beyond
  the metadata cache.
- Keychain behaviour is verified on Apple Development-signed Debug **and** Release builds, both
  of which use the login keychain. The data protection keychain is preferred and refuses this
  app with `errSecMissingEntitlement (-34018)`, because a macOS app with these capabilities is
  signed without a provisioning profile and so has no keychain access group. No Developer ID
  certificate is installed on the development machine, so a distribution build — which is where
  that path would be exercised — has not been produced. See
  [Docs/ReleaseVerification.md](Docs/ReleaseVerification.md).
- A clean build prints one `appintentsmetadataprocessor` note about there being no
  `AppIntents.framework` dependency. It is stdout from a build phase Xcode runs for every app
  target, not a project warning, and silencing it would mean adding an App Intent the app has no
  use for.

## Repository layout

```
InboxSweep/               App target
  App/                    Entry point and composition root
  Domain/                 Provider-agnostic models, aggregation, boundaries
    Persistence/          The cache protocol and the window it stores
  Application/            Session state for the UI
  Providers/Gmail/        Gmail adapter (the only Gmail-aware code)
  Providers/Persistence/  On-disk cache, plan, and mutation-record stores
  Providers/Sample/       Synthetic mailbox, debug builds only
  Providers/Networking/   HTTPTransport seam
  UI/                     SwiftUI views
  Config/                 Your local OAuth client plist (gitignored)
InboxSweepTests/          Unit tests, fixtures, and test doubles
InboxSweepUITests/        Launch and dashboard UI tests
Docs/                     OAuth setup, session restore, archiving, activity, release verification
```

## Licence

See [LICENSE](LICENSE).

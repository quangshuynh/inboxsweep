# InboxSweep

A privacy-conscious Gmail cleanup assistant for macOS.

**InboxSweep recommends; you authorize.** This version does not even recommend yet — it reads
your Gmail metadata, groups it by sender, reports factual observations about each one, and
shows you who is filling your inbox. It has no ability to delete, archive, label, move,
unsubscribe, or send mail.

> **Read-only.** InboxSweep requests a single Gmail permission that cannot modify a mailbox,
> and the app contains no code that writes to one. See [Privacy posture](#privacy-posture).

<!-- macOS · SwiftUI · Swift 6 -->

## What it does

- Connects a Google account with OAuth 2.0 (authorization code + PKCE, no client secret).
- Requests exactly one scope: `gmail.metadata` — headers, labels, and dates. Not bodies.
- Fetches a bounded window of message metadata (250 messages by default) with bounded
  concurrency, cancellation support, and pagination.
- Normalizes Gmail's responses into app-owned domain models.
- Groups messages by sender and shows per-sender counts in a native macOS dashboard.
- Reports **sender observations** — Gmail's own categories, `List-Unsubscribe` presence,
  read/unread counts, the span of loaded mail, and how often the sender arrives.
- Opens a sender to list the loaded messages behind its row: subject, date, read state,
  starred and important state, categories, and whether the message carried an unsubscribe
  header.
- **Saves the loaded window to this Mac**, so relaunching restores the dashboard without
  re-reading the mailbox, and says on screen when what you are looking at came from disk.
- Handles signed-out, restoring, connecting, loading, loaded, empty, and error states.
- Runs entirely against synthetic data when no Google account is configured, so the whole app
  can be developed and tested offline.

## What it deliberately does not do

None of the following is implemented, and the UI does not pretend otherwise:

| Not implemented | |
| --- | --- |
| Delete, trash, or archive | Mark as read, star, or label |
| Unsubscribe (of any kind) | Bulk actions on senders |
| Newsletter/promotion classification | "Useless sender" or cleanup scoring |
| AI classification of any message | Cleanup rules or scheduling |
| Background monitoring or notifications | Storage-savings estimates |
| Analytics or telemetry | CI, badges, or releases |

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
              InboxCacheStoring, CachedInbox     InboxSweep/Domain/Providers
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
asserts this, and separately asserts that every Gmail API request the app can construct is a
`GET`.

One practical consequence of the narrower scope: Gmail rejects search queries (`q=`) under
`gmail.metadata`. The fetch layer works within that limit rather than widening the scope.

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

No test requires a Google account, a network connection, or real mailbox data. Fixtures use
RFC 2606 reserved domains (`example.com`, `example.org`, `example.net`) throughout, and the
persistence tests write to a temporary directory rather than to your own container.

To run only the unit tests:

```bash
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep -destination 'platform=macOS' test -only-testing:InboxSweepTests
```

## Privacy posture

Claims below describe what this version actually does. Nothing more is implied.

- **Read-only access.** The one scope requested cannot change a mailbox, and the app contains
  no code path that writes to one.
- **No message is altered, moved, or deleted.** There is no feature to do so.
- **Metadata only.** Message requests use `format=metadata` with four named headers (`From`,
  `Subject`, `Date`, `List-Unsubscribe`). Bodies and attachments are never requested and there
  is nowhere in the domain model to put them.
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

## Repository layout

```
InboxSweep/               App target
  App/                    Entry point and composition root
  Domain/                 Provider-agnostic models, aggregation, boundaries
    Persistence/          The cache protocol and the window it stores
  Application/            Session state for the UI
  Providers/Gmail/        Gmail adapter (the only Gmail-aware code)
  Providers/Persistence/  On-disk cache store and its file format
  Providers/Sample/       Synthetic mailbox, debug builds only
  Providers/Networking/   HTTPTransport seam
  UI/                     SwiftUI views
  Config/                 Your local OAuth client plist (gitignored)
InboxSweepTests/          Unit tests, fixtures, and test doubles
InboxSweepUITests/        Launch and dashboard UI tests
Docs/                     OAuth setup guide and plist template
```

## Licence

See [LICENSE](LICENSE).

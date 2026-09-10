# InboxSweep

A privacy-conscious Gmail cleanup assistant for macOS.

**InboxSweep recommends; you authorize.** This first version does not even recommend yet — it
reads your Gmail metadata, groups it by sender, and shows you who is filling your inbox. It
has no ability to delete, archive, label, move, or send mail.

> **Read-only.** Interval 1 requests a single Gmail permission that cannot modify a mailbox,
> and the app contains no code that writes to one. See [Privacy posture](#privacy-posture).

<!-- Interval 1 · macOS · SwiftUI · Swift 6 -->

## What Interval 1 does

- Connects a Google account with OAuth 2.0 (authorization code + PKCE, no client secret).
- Requests exactly one scope: `gmail.metadata` — headers, labels, and dates. Not bodies.
- Fetches a bounded window of message metadata (250 messages by default) with bounded
  concurrency, cancellation support, and pagination.
- Normalizes Gmail's responses into app-owned domain models.
- Groups messages by sender and shows per-sender counts in a native macOS dashboard.
- Handles signed-out, restoring, connecting, loading, loaded, empty, and error states.
- Runs entirely against synthetic data when no Google account is configured, so the whole app
  can be developed and tested offline.

## What Interval 1 deliberately does not do

None of the following is implemented, and the UI does not pretend otherwise:

| Not implemented | |
| --- | --- |
| Delete, trash, or archive | Mark as read, star, or label |
| Unsubscribe (of any kind) | Bulk actions on senders |
| Newsletter/promotion classification | "Useless sender" or cleanup scoring |
| AI classification of any message | Cleanup rules or scheduling |
| Background monitoring or notifications | Storage-savings estimates |
| Analytics or telemetry | CI, badges, or releases |

`List-Unsubscribe` headers are *recorded* as an observation for a later interval. Nothing in
this version reads that flag to decide anything, and the app never contacts an unsubscribe URL.

## Architecture

Dependencies point in one direction. Domain code imports no Gmail types and no Google
frameworks; the Gmail adapter is reachable only through protocols the domain owns.

```
UI            SwiftUI views                      IndexSweep/UI
  ↓
Application   InboxSessionModel, InboxSnapshot   IndexSweep/Application
  ↓
Domain        EmailAddress, MailMessage,         IndexSweep/Domain/Models
              SenderSummary, SenderAggregator    IndexSweep/Domain/Aggregation
  ↓
Boundaries    MailProvider, MailAccountAuthorizing,
              MailMessageFetching, MailProviderError
                                                 IndexSweep/Domain/Providers
  ↓
Adapters      GmailProvider + OAuth, API client, IndexSweep/Providers/Gmail
              normalizer, keychain store
              SampleMailProvider (debug only)    IndexSweep/Providers/Sample
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

## Getting started

**Requirements:** macOS 26.5+, Xcode 26.6+.

```bash
git clone <this repo>
cd IndexSweep
open IndexSweep.xcodeproj
```

The app runs without any Google configuration. The signed-out screen will explain that
sign-in is not set up, and in a Debug build an **Explore with sample data** button opens the
dashboard on a synthetic mailbox.

To connect a real account, follow **[Docs/OAuthSetup.md](Docs/OAuthSetup.md)**.

### Build

```bash
xcodebuild -project IndexSweep.xcodeproj -scheme IndexSweep -configuration Debug -destination 'platform=macOS' build
```

### Test

```bash
xcodebuild -project IndexSweep.xcodeproj -scheme IndexSweep -destination 'platform=macOS' test
```

No test requires a Google account, a network connection, or real mailbox data. Fixtures use
RFC 2606 reserved domains (`example.com`, `example.org`, `example.net`) throughout.

To run only the unit tests:

```bash
xcodebuild -project IndexSweep.xcodeproj -scheme IndexSweep -destination 'platform=macOS' test -only-testing:IndexSweepTests
```

## Privacy posture

Claims below describe what this version actually does. Nothing more is implied.

- **Read-only access.** The one scope requested cannot change a mailbox, and the app contains
  no code path that writes to one.
- **No message is altered, moved, or deleted.** There is no feature to do so.
- **Metadata only.** Message requests use `format=metadata` with four named headers (`From`,
  `Subject`, `Date`, `List-Unsubscribe`). Bodies and attachments are never requested and there
  is nowhere in the domain model to put them.
- **Local by default.** Message metadata lives in memory for the life of the process. The
  networking layer uses an ephemeral `URLSession`, so responses are not written to an on-disk
  URL cache. InboxSweep sends your mail to no server other than Google's own API.
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
- The Xcode project, target, and bundle identifier are still named `IndexSweep`; only the
  product's display name is `InboxSweep`. Renaming is a separate, deliberate change.
- The macOS deployment target inherited from the project template is 26.5, which is unusually
  high for a shipping app. Nothing in the code requires it.

## Repository layout

```
IndexSweep/               App target
  App/                    Entry point and composition root
  Domain/                 Provider-agnostic models, aggregation, boundaries
  Application/            Session state for the UI
  Providers/Gmail/        Gmail adapter (the only Gmail-aware code)
  Providers/Sample/       Synthetic mailbox, debug builds only
  Providers/Networking/   HTTPTransport seam
  UI/                     SwiftUI views
  Config/                 Your local OAuth client plist (gitignored)
IndexSweepTests/          Unit tests, fixtures, and test doubles
IndexSweepUITests/        Launch and dashboard UI tests
Docs/                     OAuth setup guide and plist template
```

## Licence

See [LICENSE](LICENSE).

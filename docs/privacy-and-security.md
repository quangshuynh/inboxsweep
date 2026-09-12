# Privacy and security

Everything on this page describes what this version actually does. Nothing more is implied,
and the [limits of these claims](#what-is-not-claimed) are stated at the bottom rather than
left out.

## The three things it can change

InboxSweep can make exactly three kinds of change to a mailbox. There are no others, and each
one is documented in full on its own page.

| Change | Reversible | Needs | Page |
| --- | --- | --- | --- |
| Remove `INBOX` from a message you ticked | Yes, by a real Gmail request | A selection and a confirmation naming every message | [Archiving and undo](archive-and-undo.md) |
| Send one unsubscribe request | **No** | Two confirmations, and the destination shown first | [Unsubscribing](unsubscribe.md) |
| Archive newly loaded mail from one authorized sender | **No** | A rule you created on its own screen | [Sender rules](rules.md) |

!!! warning "Archiving is not deleting"

    In Gmail a message is in the Inbox exactly when it carries the `INBOX` label, so archiving
    one *is* removing that label. The message stays in All Mail, keeps its read state, its star,
    its importance marker, and its Gmail category, and is found by search as before.

!!! warning "An unsubscribe request is not a completed unsubscription"

    InboxSweep sends the request the sender's own headers describe. Whether the sender honours
    it, how long it takes, and whether mail stops arriving are entirely the sender's to decide.
    The app records that a request was sent and never claims more than that.

## What it never does

- **No message is deleted, trashed, marked, starred, labelled, or sent.** There is no feature to
  do any of it, and the app never requests a scope that would permit permanent deletion.
- **Nothing acts on its own, or on anything you did not name.** There is no archive-sender,
  archive-all, cross-sender, execute-plan, or scheduled operation. A cleanup planner produces a
  *description* of what an action would reach; building one makes no request of any kind, and
  the only thing that description can do is pre-tick checkboxes you then inspect, edit, and
  confirm yourself.
- **Nothing runs while the app is closed.** There is no background agent, no launch daemon, no
  notification, and no scheduler. A [sender rule](rules.md) is the closest thing to automation
  in the app, and it runs only while InboxSweep is loading mail.
- **No AI.** No message, header, or subject is sent to any AI service. The proposal engine is a
  keyword list and a set of counting rules, and it says so.
- **No analytics, no telemetry, no crash reporting.** There is no third-party runtime dependency
  of any kind.

## Metadata only

Message requests use `format=metadata` with five named headers: `From`, `Subject`, `Date`,
`List-Unsubscribe`, and `List-Unsubscribe-Post`. Bodies and attachments are never requested,
even though the `gmail.modify` scope would now permit them, and there is nowhere in the domain
model to put them if they arrived.

That is structural rather than a rule someone has to remember: `MailMessage` has no field for a
body, so a cache file cannot hold mail content even in principle.

## Credentials

| | |
| --- | --- |
| Your Google password | Typed into Google's own window (`ASWebAuthenticationSession`, ephemeral session). InboxSweep never sees it |
| Refresh token | macOS Keychain |
| Access token | Memory only, for the life of the process. Never written to the cache |
| OAuth client secret | None exists. The app uses a public iOS/macOS client with PKCE |
| Client ID | Supplied at runtime from a gitignored path or an environment variable |

Signing out asks Google to revoke the grant, deletes the Keychain item, and deletes every local
file.

**No Google token ever leaves Google.** A [one-click unsubscribe](unsubscribe.md) goes to the
sender's own host over a transport that has never held a credential: no `Authorization` header,
no cookie, and nothing about your mailbox. A test connects a real provider, mints a token, and
proves none of it appears in what the unsubscribe request carried.

## What is stored on this Mac

The loaded window is written to one JSON file inside the app's own sandbox container, so a
relaunch restores the dashboard instead of re-reading the mailbox.

**Where:** `Library/Application Support/InboxSweep/Cache/` inside
`~/Library/Containers/quang.InboxSweep/Data/`, in a file named after a SHA-256 digest of the
account address, written atomically with `0600` permissions and excluded from backups.

| Stored | Not stored |
| --- | --- |
| Provider message and thread IDs | Message bodies |
| Sender name and address | Attachments or their contents |
| Subject line | Access tokens |
| Received date | Refresh tokens, which stay in the Keychain |
| Labels, including Gmail's categories | Raw Gmail API responses |
| The unsubscribe destinations parsed from headers | Anything else the API returned |
| Derived sender summaries and the next-page cursor | |

How it behaves:

- **One account at a time.** The file is keyed by account, a load refuses to hand back a window
  whose stored address does not match, and a save deletes any other account's file. A second
  account can never show the first one's mail.
- **Restored windows are labelled.** The dashboard header says the window came from this Mac and
  when it was read. Adding a page to a restored window does not make the older pages look
  freshly read.
- **Pagination survives a relaunch.** The next-page cursor is stored, so **Load more messages**
  continues from where the last launch stopped.
- **Derived data is checked, not trusted.** Stored sender summaries are used only when they still
  add up to the stored messages; otherwise they are rebuilt from them.
- **Invalidation is safe.** A file with an unrecognised schema version, or one that is truncated,
  corrupt, or written for another account, is discarded and the mailbox is fetched as if nothing
  had been stored. Nothing here throws: a cache that cannot be read is a refetch, and a cache
  that cannot be written is a refetch next launch.
- **Sample data is never written.** The synthetic mailbox runs on the no-op cache.

Three smaller files sit beside it, with the same permissions, the same container, and the same
deletion on disconnect: your [saved plans](cleanup-proposals.md#saved-plans), the
[mutation history](activity.md) behind Activity and undo, and your
[sender rules](rules.md#the-one-new-thing-on-disk).

!!! note "The rules file is the one place a sender is written down"

    A rule has to name the address it matches, so a rules file is the first thing InboxSweep
    writes that names a **sender** rather than a message ID. That cost is stated on the
    [Sender rules](rules.md#the-one-new-thing-on-disk) page rather than buried, along with how
    it is bounded.

## Networking

The networking layer uses an ephemeral `URLSession`, so responses are not written to an on-disk
URL cache. InboxSweep sends your mail to no server other than Google's own API. The only other
destination it can reach is a sender's unsubscribe endpoint, and only on a confirmation, over a
[redirect policy](unsubscribe.md#redirect-policy) that is deliberately narrow.

## How the limits are enforced

The scope Google grants is [broader than what the app does with it](gmail-integration.md#the-permissions-it-asks-for),
so the restraint lives in the code. `SafetyBoundaryTests` is the suite that pins it down, and it
is mostly a test of an *absence*. It asserts that:

- every **read** request the app can construct is a `GET` reaching no mutating path;
- there are exactly **two** mutating requests, both `POST`s to
  `users/me/messages/{id}/modify`, never to a thread or a batch endpoint;
- their bodies name `INBOX` and no other label, and carry one instruction each;
- a message identifier is percent-encoded into a single path segment and cannot redirect a
  request;
- loading, previewing, saving a plan, restoring one, re-sorting, and reloading reach the
  mutation boundary **zero** times;
- a provider is read-only unless it deliberately vends an archiver;
- `SenderSummary` has no property named for a judgement, so no score can leak into the facts;
- the scope list contains neither `https://mail.google.com/` nor any send, compose, insert,
  label, settings, or contacts permission.

A change that quietly added a mutating scope, a second kind of write, a bulk operation, or a
message body to the domain model fails there rather than in someone's mailbox. See
[Testing](testing.md).

## Repository hygiene

Everything committed to this repository is synthetic. Fixtures use the domains RFC 2606 and
RFC 6761 reserve for documentation, and the persistence tests write to a temporary directory
rather than to your own container.

Two checks in [CI](testing.md#continuous-integration) enforce the parts that have a mechanical
answer: `Scripts/check_privacy.sh` fails the build on an address outside those reserved domains,
on credential-shaped content of plausible length, on a file that belongs only on one developer's
Mac, and on any absolute path into a home directory. It cannot prove the absence of real data,
and says so in its own comments.

## What is not claimed

- The local files are protected by the app sandbox, file permissions, and whatever full-disk
  encryption the Mac has. **InboxSweep does not encrypt them itself.**
- The app has **not been independently audited** and makes **no anonymity guarantees**.
- There is no notarized or Developer ID-signed build. Keychain behaviour has been verified on
  Apple Development-signed Debug and Release builds only; see [Limitations](limitations.md).
- A user auditing the grant in their Google Account will see a broad permission. The app's
  limits are not visible from there.
- Nothing here protects you from Google. InboxSweep reduces what leaves your Mac; it has no
  effect on what Google already holds.

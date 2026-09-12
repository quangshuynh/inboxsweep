# Limitations

This page is first-class rather than a footnote. Everything below is a real constraint of this
version, stated plainly.

## The loaded window

- **Counts describe what has been loaded, not your mailbox.** The default window is the 250 most
  recent inbox messages. The interface says "Messages loaded" and shows how far back the window
  reaches for exactly this reason. **Load more messages** extends it a page at a time, and the
  extended window is what gets stored.
- **A restored window is as old as its label says.** InboxSweep never refreshes it on its own and
  there is no background monitoring, so **Reload** is the only thing that fetches current mail.
- **Sender observations describe the loaded window only.** Loading more messages can change a
  sender's frequency, category set, and unsubscribe count, and it is meant to.
- **Each load reads one scope.** Changing between Inbox, one of Gmail's four categories, and All
  mail discards the loaded window and reads the new scope, because a window mixing two of them
  would make every count describe something nobody could name.
- **The ceiling is 2,500 messages, not "your whole mailbox".** Every depth is finite, because a
  message costs a metadata request.

## Proposals

- **Proposals are only as good as a keyword list.** Protection is decided by matching literal
  phrases in subject lines, so it will miss a bank whose subjects are opaque and will flag a
  newsletter about tax software. Every protection warning shows the evidence behind it for exactly
  this reason.
- **Proposals describe the loaded window, not the mailbox.** A long-running newsletter contributes
  only its recent issues to a 250-message window. The dry-run preview states which case applies.
- **The planner offers a fixed set of cutoffs**: keep the newest 5, or cut at 30 or 90 days. There
  is no way to type an arbitrary one, though a saved plan's file format would carry one.

## Archiving

- **Archiving is per sender and explicitly selected, by design.** There is no sender-level
  one-click archive, no cross-sender cleanup, and no way to carry out a previewed plan. A large
  cleanup means ticking the messages and confirming the list, which is the point rather than an
  oversight.
- **Sender-level review preselects from the loaded window only.** A sender with four hundred
  messages of which 250 are loaded gets candidates from the 250.
- **A large set takes as long as it takes.** Messages go out one request at a time, so a set of
  several hundred is a visible wait. The alternative, `batchModify`, reports no per-message result
  and [was rejected for that reason](archive-and-undo.md#one-request-per-message-and-not-batchmodify)
  rather than for performance.
- **Only the most recent archive is undoable, per account.** Archiving again supersedes the
  previous offer. There is no undo stack and no way to reach an older one: once an offer is gone,
  those messages are in All Mail and moving them back is a Gmail operation.
- **Archiving is message-level**, so a conversation whose other messages are still in the Inbox
  stays in the Inbox. That matches Gmail's own behaviour but can surprise anyone expecting a
  thread to disappear.
- **The message review is per sender.** There is no way to see every loaded message at once.

## Unsubscribing

- **It cannot be undone**, and the app says so before you decide.
- **A request is not a completed unsubscription.** Whether the sender honours it is the sender's
  to decide, and the app never claims more than that a request was sent.
- **Only what the sender published counts.** A sender that publishes no `List-Unsubscribe` header
  offers nothing to act on, and the link in the message body is something InboxSweep cannot see.
- **The browser and mail handoffs end at the handoff.** Whether you finished the flow is not
  something the app can observe.

## Rules

- **A sender rule does nothing while InboxSweep is closed.** It is not a Gmail filter and the app
  holds no permission to create one, so matching mail arrives in your Inbox as usual and is
  archived the next time you open the app or press Reload. If you want mail never to reach your
  Inbox, that is a filter you make in Gmail.
- **A rule-driven archive has no undo.** The app keeps one undoable archive per account, and
  letting something automatic take that offer would mean losing an undo you meant to keep.
- **One exact address per rule.** A sender who mails you from several addresses needs several
  rules. At most 25 rules, at most 50 messages per pass.

## Permissions

- **`gmail.modify` grants more than the app uses.** Google publishes nothing narrower that can
  archive, so the restraint is enforced by the code and its tests rather than by the permission.
  A user auditing the grant in their Google Account will see a broad permission, and the app's
  limits are not visible from there.
- **A restricted-scope OAuth client stays in Google's "Testing" mode without verification**, so
  only accounts listed as test users can sign in during development.
- **Gmail rejects search queries under `gmail.metadata`.** The fetch layer works within that
  limit.

## Storage

- **The cache is not migrated between schema versions.** A version bump discards the stored window
  and the next launch fetches it again.
- **Gmail label names for custom labels are not resolved.** Unknown labels are carried through by
  their provider-side identifier.
- **A saved plan holds sender addresses on disk**, as does a rules file. Both are in the app's
  container, both are deleted on disconnect, and they are the two places a list of who writes to
  you is written unencrypted beyond the metadata cache.
- **The local files are not encrypted by InboxSweep.** They are protected by the app sandbox,
  file permissions, and whatever full-disk encryption the Mac has.
- **The mutation record is not fully surfaced.** [Activity](activity.md) reads it, but the record
  keeps more than the screen shows.

## Interface

- **The dashboard sorts through a toolbar picker.** The table's column headers are not clickable.
- **Sender detail lists the loaded messages but cannot open one.** There is no body to show.

## Build and platform

- **macOS only.** There is no iOS, iPadOS, or web version, and no plan for one.
- **The deployment target is macOS 26.5**, inherited from the project template and unusually high
  for a shipping app. Nothing in the code requires it.
- **There is no notarized or Developer ID-signed build.** Keychain behaviour is verified on Apple
  Development-signed Debug **and** Release builds, both of which use the login keychain. The data
  protection keychain is preferred by the code and refuses this app with
  `errSecMissingEntitlement (-34018)`, because a macOS app with these capabilities is signed
  without a provisioning profile and so has no keychain access group. No Developer ID certificate
  is installed on the development machine, so a distribution build, which is where that path would
  be exercised, has not been produced.
- **A clean build prints one `appintentsmetadataprocessor` note** about there being no
  `AppIntents.framework` dependency. It is stdout from a build phase Xcode runs for every app
  target, not a project warning, and silencing it would mean adding an App Intent the app has no
  use for.

## What has not been verified

- **The app has not been independently audited**, and it makes no anonymity guarantees.
- **Nothing here protects you from Google.** InboxSweep reduces what leaves your Mac; it has no
  effect on what Google already holds.
- **There is no release.** No tag, no notarized artifact, no distribution channel. See
  [Roadmap](roadmap.md).

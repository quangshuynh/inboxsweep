<p align="center">
  <img src="docs/images/inboxsweep-logo.png" alt="InboxSweep" width="140">
</p>

<h1 align="center">InboxSweep</h1>

<p align="center">
  <strong>A privacy-conscious Gmail cleanup assistant for macOS.<br>
  It recommends; you authorize.</strong>
</p>

<!--
  The CI badge below renders once this repository is public. GitHub serves workflow badges for a
  private repository only to an authenticated session, and a README image is fetched through an
  unauthenticated proxy, so it shows as a broken image until then. The link works either way.

  There is deliberately no badge for the documentation site: GitHub Pages is not enabled on this
  repository, so a badge for it would claim something that is not true.
-->
<p align="center">
  <a href="https://github.com/quangshuynh/inboxsweep/actions/workflows/ci.yml"><img src="https://github.com/quangshuynh/inboxsweep/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2026.5%2B-lightgrey" alt="macOS 26.5+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/licence-MIT-blue" alt="MIT licence">
</p>

---

InboxSweep reads your Gmail **metadata**, groups it by sender, says which senders look worth
cleaning up and why, and shows what a cleanup *would* affect before anything happens. Mail
bodies are never requested, nothing is ever deleted, and no recommendation can carry itself out.

It is a native SwiftUI app with no server, no account, no analytics, and no AI.

## Features

- **Sender dashboard.** A bounded window of message metadata, grouped by sender, with counts,
  Gmail categories, read state, cadence, and unsubscribe evidence, all scoped to what has
  actually been loaded and labelled as such.
- **Cleanup proposals with their reasons attached.** A pure, clockless engine that says which
  senders look like bulk mail and prints the evidence beside the verdict. Protection runs first
  and can only veto.
- **Dry-run previews.** What a cleanup would affect, calculated over the window already in
  memory. Building one makes no request of any kind.
- **Archive and undo.** Removes the `INBOX` label from the messages you ticked and confirmed as a
  list, one request at a time, with a per-message outcome. Undo is a real Gmail request and
  survives quitting the app.
- **Safe unsubscribe.** Reads the `List-Unsubscribe` headers a sender wrote, shows the exact
  destination, and sends one standards-defined request only after you confirm.
- **Sender rules.** One exact address, one action, running only while the app is loading mail.
- **Activity.** What InboxSweep itself changed, holding counts and message identifiers and no
  mail.
- **Offline by default.** A synthetic mailbox drives the whole app, and the entire UI suite, with
  no account and no network.

## Privacy and safety

- **One kind of write, and you confirm each one.** Archiving removes the `INBOX` label from a
  message you selected, and undo puts it back. Those two requests are the complete set of
  mutations the app can construct.
- **Archiving is not deleting.** Nothing is deleted, trashed, marked, labelled, or sent, and the
  app never requests a scope that would permit permanent deletion.
- **Metadata only.** Message requests use `format=metadata` with five named headers. There is
  nowhere in the domain model to put a body.
- **Nothing runs while the app is closed.** No scheduler, no background agent, no notifications.
  A sender rule is not a Gmail filter and cannot become one.
- **No AI, no analytics, no telemetry**, and no third-party runtime dependency of any kind.
- **Local by default.** Metadata lives in memory and in one file inside the app's own sandbox
  container. The refresh token is in the Keychain; access tokens never touch disk. Disconnecting
  revokes the grant and deletes every local file.
- **No Google token ever leaves Google.** A one-click unsubscribe goes to the sender's own host
  over a transport that has never held a credential.

Full detail, including [what is not claimed](docs/privacy-and-security.md#what-is-not-claimed),
is on the [Privacy and security](docs/privacy-and-security.md)
page.

## Quick start

**Requirements:** macOS 26.5+, Xcode 26.6+.

```bash
git clone https://github.com/quangshuynh/inboxsweep.git
cd inboxsweep
open InboxSweep.xcodeproj
```

Press Run. The app works immediately with no Google configuration: a Debug build offers
**Explore with sample data**, which opens the whole dashboard on a synthetic mailbox.

```bash
# Build
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep \
  -configuration Debug -destination 'platform=macOS' build

# Test
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep \
  -destination 'platform=macOS' test
```

To connect a real account, follow
[Connecting Gmail](docs/gmail-integration.md).

## Documentation

Everything beyond this page lives in [`docs/`](docs/), built as a site with MkDocs:

```bash
pip install -r requirements-docs.txt
mkdocs serve
```

GitHub Pages is not enabled on this repository yet, so there is no hosted copy to link. The
deploy workflow is committed and ready; turning on **Settings > Pages > Source: GitHub Actions**
publishes it to `https://quangshuynh.github.io/inboxsweep/`.

| | |
| --- | --- |
| [Install and run](docs/getting-started.md) | Requirements, building, first connect |
| [Connecting Gmail](docs/gmail-integration.md) | OAuth setup, and what each scope means |
| [Cleanup proposals](docs/cleanup-proposals.md) | How a recommendation is calculated, and why it cannot execute |
| [Archiving and undo](docs/archive-and-undo.md) | The confirmation, partial failure, undo lifetime |
| [Unsubscribing](docs/unsubscribe.md) | The five states, the three mechanisms, the redirect policy |
| [Sender rules](docs/rules.md) | The one standing authorization, and its bounds |
| [Activity](docs/activity.md) | What is recorded, and what deliberately is not |
| [Architecture](docs/architecture.md) | Layers, seams, and the decisions behind them |
| [Privacy and security](docs/privacy-and-security.md) | Every claim, and the limits of each |
| [Testing](docs/testing.md) | The suites, CI, and what a clean runner measured |
| [Limitations](docs/limitations.md) | What it cannot do |

## Status

macOS only, built with SwiftUI and Swift 6. A personal project rather than a shipping product:
there is no notarized build, no release, and no independent security audit. Both configurations
are built clean and both test suites are run on every push.

## Licence

MIT. See [LICENSE](LICENSE).

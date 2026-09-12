# Install and run

InboxSweep is a macOS app built from source. There is no notarized download, no installer, and
no release build to fetch.

## Requirements

| | |
| --- | --- |
| Operating system | macOS 26.5 or later |
| Toolchain | Xcode 26.6 or later |
| Language | Swift 6 |
| Google account | Optional. The app runs fully without one. |

The deployment target is high because it was inherited from the project template, not because
anything in the code needs it. See [Limitations](limitations.md).

## Build and run

```bash
git clone https://github.com/quangshuynh/InboxSweep.git
cd InboxSweep
open InboxSweep.xcodeproj
```

Press Run. **The app works immediately with no Google configuration.** The signed-out screen
explains that sign-in is not set up, and a Debug build offers **Explore with sample data**,
which opens the whole dashboard on a synthetic mailbox: senders, proposals, dry-run previews,
message review, and Activity, with no network access and nothing real behind any of it.

That synthetic mailbox is not a demo mode bolted on the side. It is a provider like any other,
and it is what the entire UI test suite runs against.

## From the command line

```bash
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep \
  -configuration Debug -destination 'platform=macOS' build
```

```bash
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep \
  -configuration Release -destination 'platform=macOS' build
```

Both configurations are built clean on every push by
[CI](https://github.com/quangshuynh/InboxSweep/actions/workflows/ci.yml). See
[Testing](testing.md) for how to run the suites.

## Connecting a real mailbox

InboxSweep needs its own Google OAuth client, which is tied to your own Google Cloud project
and is therefore not committed here. [Connecting Gmail](gmail-integration.md) walks through
creating one.

Until you do, everything below is still available:

- the signed-out screen, which states what the app will and will not ask for;
- the synthetic mailbox and every screen reachable from it;
- the full unit and UI test suites, none of which need an account, a network, or real mail.

## What happens on first connect

1. **Connect Gmail** opens Google's own sign-in window. InboxSweep never sees your password.
2. Google's consent screen asks for two permissions. What they mean, and why the second one is
   broader than what the app does with it, is in [Connecting Gmail](gmail-integration.md).
3. The app fetches a bounded window of message metadata, by default the 250 most recent inbox
   messages, and groups it by sender.
4. That window is written to one file inside the app's own sandbox container so the next launch
   restores the dashboard without re-reading the mailbox. The header says when the window was
   read and offers **Reload**.

Nothing in that sequence changes your mailbox. The first thing that can is described in
[Archiving and undo](archive-and-undo.md), and it takes a selection and a confirmation.

## Signing out

**Disconnect** asks Google to revoke the grant, deletes the Keychain item, deletes the cached
window, deletes any saved cleanup plans, deletes the local record of what was changed, and
deletes your sender rules. Nothing is left behind on this Mac and nothing survives at Google.

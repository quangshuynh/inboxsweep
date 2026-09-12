# Roadmap

InboxSweep is a personal project built in intervals, each one adding a single capability and its
tests. This page says where it has got to and what it is deliberately not going to become.

## Where it is

| | |
| --- | --- |
| Platform | macOS only |
| Distribution | Source only. No release, no tag, no notarized build |
| Reading | Bounded metadata windows over Inbox, Gmail's four categories, or All mail |
| Recommending | Sender observations, cleanup proposals, dry-run previews, saved plans |
| Writing | [Archive and undo](archive-and-undo.md), [one unsubscribe request](unsubscribe.md), [sender rules](rules.md) |
| Verification | Unit and UI suites, plus [CI on a hosted runner](testing.md#continuous-integration) |

## Not planned, and why

These are not "not yet". They are decisions, and several of them are the reason the app is worth
using.

| | |
| --- | --- |
| **Delete, trash, or permanent removal** | The app never requests a scope that would permit it. Adding one would make every other claim on the [privacy page](privacy-and-security.md) weaker |
| **Bulk or automatic unsubscribe** | A request that cannot be undone should be one at a time, confirmed, with the destination on screen |
| **Executing a cleanup plan** | [Proposals recommend; users authorize.](cleanup-proposals.md#why-proposals-are-not-executable) A plan that could run itself is a different app |
| **Background or scheduled operation** | Nothing runs while the app is closed. That is a promise rather than a missing feature |
| **AI classification** | No message, header, or subject goes to any classifier. The proposal engine is a keyword list and says so |
| **Analytics, telemetry, crash reporting** | There is no third-party runtime dependency, and adding one would mean mail metadata leaving the Mac by a route nobody asked for |
| **A backend of any kind** | There is no server and no account. Nothing to breach |
| **Gmail filters, blocking, server-side rules** | The app holds no permission to create one and is not asking for it |
| **Other mail providers** | The seams would allow it. Nobody has written an adapter, and claiming support before one exists would be a lie |

## What a next step would look like

Nothing here is committed work, and none of it is in progress.

- **A Developer ID-signed build.** The one meaningful gap in verification: the data protection
  keychain path is currently unreachable because the app is signed without a provisioning profile,
  and a distribution build is where that path would actually be exercised. See
  [Limitations](limitations.md#build-and-platform).
- **A lower deployment target.** The current one is inherited from the project template and
  nothing in the code needs it.
- **Sorting from the table's column headers**, which today is a toolbar picker only.
- **A cross-sender message review**, which today is per sender.
- **Surfacing more of the mutation record.** [Activity](activity.md) reads it, but the record
  keeps more than the screen shows.

## Releases

There are none. No tag has been cut, no artifact is published, and this site does not link to a
download because there is nothing to download. Building from source is the only supported route,
and [Install and run](getting-started.md) is the whole of it.

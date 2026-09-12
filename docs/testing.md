# Testing

No test requires a Google account, a network connection, or real mailbox data. Fixtures use the
domains RFC 2606 and RFC 6761 reserve for documentation, and the persistence tests write to a
temporary directory rather than to your own container.

## Running the suites

```bash
# Everything
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep \
  -destination 'platform=macOS' test

# Unit only
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep \
  -destination 'platform=macOS' test -only-testing:InboxSweepTests

# UI only
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep \
  -destination 'platform=macOS' test -only-testing:InboxSweepUITests
```

The unit tests are hosted by `InboxSweep.app`, so `KeychainCredentialStoreTests` exercises the
real `SecItem` path with the app's own bundle identifier and entitlements. It writes only
synthetic credentials under a test-only service name and deletes them afterwards.

The UI tests run against the [synthetic mailbox](development.md#the-synthetic-mailbox). Nothing
they do can reach Gmail, because the sample provider has no transport to reach it with.

## The safety boundary suite

`SafetyBoundaryTests` is the one worth reading first. It is mostly a test of an **absence**, and
it exists so that a change which quietly adds a mutating scope, a second kind of write, a bulk
operation, or a message body to the domain model fails there rather than in someone's mailbox.
What it asserts is listed in
[Privacy and security](privacy-and-security.md#how-the-limits-are-enforced).

## Continuous integration

Every push runs [`.github/workflows/ci.yml`](https://github.com/quangshuynh/inboxsweep/blob/main/.github/workflows/ci.yml)
on `macos-26` and `ubuntu-latest`:

| Job | What it does |
| --- | --- |
| **Build** | Clean Debug build and clean Release build, both from scratch |
| **Tests** | Builds for testing once, then runs the unit suite and the UI suite. The UI step runs even when the unit step failed, so one run answers both questions |
| **Docs** | `mkdocs build --strict`, then a link and image check over every page |
| **Hygiene** | The em dash scan and the privacy scan, over tracked text |

The runner is pinned to `macos-26` rather than `macos-latest`, and `DEVELOPER_DIR` names Xcode
26.6 rather than trusting the image's default. Two reasons: the deployment target is macOS 26.5,
so only Xcode 26.5 and 26.6 ship an SDK new enough to build it at all; and that image is macOS
26.6.2 (25G83) with Xcode 26.6 (17F113), the same OS build and the same Xcode as the machine the
app is developed on. A CI result and a local result are therefore comparing the same thing.

Signing on CI is **ad-hoc**. No Apple Developer identity exists on a hosted runner, and the
automatic style the project is configured with would look for one; but arm64 macOS refuses to
launch an unsigned bundle at all, so the test host still needs a real signature. Ad-hoc is the one
that is both available and sufficient.

Nothing is cached for the Xcode jobs. There is no package graph to restore, and a reused
`DerivedData` would make "clean build" mean something weaker than it says. The two Python jobs
cache pip, which is safe because `requirements-docs.txt` pins exact versions and is the cache key.

## What a clean runner measured

This suite spent three development intervals arguing with a question that could not be settled on
a developer's Mac: how much of its flakiness was the app, and how much was the desktop it ran on.

Ten consecutive complete runs on the development machine measured this:

| | Runs | Cases |
| --- | --- | --- |
| Unit | 10 of 10 clean | 0 failures in roughly 7,430 cases |
| UI | **6 of 10 clean** | 9 failures in 200 cases, 4.5% |

Every one of the nine failures had the same shape: an element the runner found a moment earlier
became unreachable, or a click was accepted and did nothing. That is what another application
taking the screen looks like from the runner's side, and the runner's own logs named the
applications. The [deterministic window harness](development.md#the-deterministic-window-harness)
exists because of it, and puts the app on a full-screen Space of its own so there is nothing left
to be behind.

A hosted runner is the clean-desktop experiment that machine could not provide. What it found is
recorded in [Signed Release verification](release-verification.md#what-ci-measured-about-the-ui-harness).

## Checking that a sign-in survives a relaunch

A launch argument writes a synthetic Keychain marker, reports what it found, and exits, so
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

All four work in Release as well as Debug: the signed Release app is the build whose Keychain
behaviour most needs measuring. All four are inert without their launch argument, reach no UI, and
print no token, refresh token, authorization code, or client secret. The probes write synthetic
markers under diagnostic-only service names and delete them, and
`CredentialStoreDiagnosticsTests` asserts both the cleanup and the absence of secrets in the
output.

Measured results and the signing configuration behind them are in
[Signed Release verification](release-verification.md); the design is in
[Session restore](session-restore.md).

## Repository hygiene checks

```bash
Scripts/check_no_em_dashes.sh   # zero U+2014 in tracked text
Scripts/check_privacy.sh        # synthetic fixtures only
python3 Scripts/check_docs_links.py
```

All three run in CI. They scan the files Git actually tracks, so build output, `DerivedData`, and
anything untracked are outside them by construction. The privacy scan pins the shapes that have a
mechanical answer and says in its own comments that it cannot prove the absence of the rest.

## What is not tested

- **No live Gmail account is exercised by any suite.** The Gmail adapter is tested against a
  recording transport that asserts on the exact requests, which is stronger for the properties
  that matter and weaker for "does Google behave as documented". A manual live round trip is
  recorded in [Signed Release verification](release-verification.md).
- **The data protection keychain path is unreachable on this configuration**, so it is not
  covered. See [Limitations](limitations.md#build-and-platform).
- **UI tests cover the synthetic mailbox only.** They prove the journeys work; they cannot prove
  anything about real mail.

# Signed Release verification

What was measured about how InboxSweep is signed, which Keychain that signing gets it, and
whether a real Gmail sign-in survives quitting the app — on the strongest signed build this
machine can produce.

This document records measurements. Where something was not measured it says so, and it does
not say "secure" anywhere.

---

## Why this exists

InboxSweep has never had a Gmail scope that can change anything. Before it gets one, the
question "does the credential storage actually work, in the build a user would run?" has to be
answered by evidence rather than by reading the code. Interval 4 answered it for a **Debug**
build. This answers it for a **signed Release** build, and separates what is a property of the
app from what is a property of how this machine happens to be provisioned.

---

## 1. Signing configuration

Automatic signing, team `W785GN4X52`, against the one certificate installed on this machine.

| | |
| --- | --- |
| Style | `CODE_SIGN_STYLE = Automatic` |
| Identity | `Apple Development: … (T5G5R8V962)` |
| Team | `W785GN4X52` |
| Bundle identifier | `quang.InboxSweep` |
| App Sandbox | `ENABLE_APP_SANDBOX = YES` |
| Hardened runtime | `ENABLE_HARDENED_RUNTIME = YES` (`flags=0x10000(runtime)` on the built app) |
| Entitlements file | none — capabilities come from build settings |
| Provisioning profile | **not embedded** |

### Developer ID was not available

Not assumed — asked:

```bash
security find-identity -v -p codesigning
```

returns exactly one identity, `Apple Development: … (T5G5R8V962)`. Signing a copy of the built
app with a Developer ID identity by name:

```bash
codesign --force --options runtime --sign "Developer ID Application" /path/to/InboxSweep.app
```

answers `Developer ID Application: no identity found`. There is no Developer ID Application
certificate, no Mac Installer certificate, and no Mac App Store certificate installed. None was
requested: obtaining one is a paid-account action on the developer's own Apple account, not
something a verification pass should do on their behalf.

**The strongest properly signed build available here is therefore an Apple Development-signed,
sandboxed, hardened-runtime Release build**, and that is what every result below was measured
on. Nothing was weakened to get a passing result: the sandbox stayed on, the hardened runtime
stayed on, and `CODE_SIGNING_ALLOWED=NO` was not used for any build in this document.

### Why no provisioning profile

Not an oversight and not a signing failure. Xcode's own resolved settings say so:

```bash
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep -configuration Release \
  -showBuildSettings | grep -E "PROVISIONING_PROFILE|ENTITLEMENTS_REQUIRED"
```

```
ENTITLEMENTS_REQUIRED = NO
PROVISIONING_PROFILE_REQUIRED = NO
PROVISIONING_PROFILE_SUPPORTED = YES
```

A macOS app whose only capabilities are App Sandbox and outgoing network *supports* a
provisioning profile but does not *require* one, so automatic signing neither fetches nor
embeds one. The profiles present in
`~/Library/Developer/Xcode/UserData/Provisioning Profiles/` are all iOS profiles for other
apps; none names `quang.InboxSweep` and none is for macOS.

Obtaining one would mean registering a macOS App ID for `quang.InboxSweep` against the team and
generating a Mac development profile — an action on the developer's Apple account, so it was
not taken automatically.

## 2. Entitlements on the built Release app

```bash
codesign -d --entitlements - --xml InboxSweep.app | plutil -p -
```

```
com.apple.security.app-sandbox  => true
com.apple.security.get-task-allow => true
com.apple.security.network.client => true
```

Three consequences, all of them measured rather than inferred:

- **No `com.apple.application-identifier`, no `keychain-access-groups`.** These are what a
  provisioning profile would have supplied, and they are what the data protection keychain
  derives an access group from. Without either, an app has no access group at all.
- **`get-task-allow` is present in Release.** It is added by non-distribution signing, and it
  means this binary is debuggable. A Developer ID or App Store build would not carry it. This
  is the clearest single respect in which what was verified here is *not* a distribution build.
- The designated requirement pins the bundle identifier and the signing certificate:

```bash
codesign -d -r- InboxSweep.app
```

```
designated => identifier "quang.InboxSweep" and anchor apple generic
  and certificate leaf[subject.CN] = "Apple Development: … (T5G5R8V962)"
  and certificate 1[field.1.2.840.113635.100.6.2.1] exists
```

No code directory hash appears in it, which is why a rebuild does not lose Keychain access —
see §5.

## 3. Which Keychain this build actually gets

The production store prefers the data protection keychain and falls back to the login keychain,
and **the fallback is deliberately silent**. That silence is right in production and useless
for verification: a save that got what it asked for and a save that fell back look identical.

`CredentialStoreDiagnostics` removes the ambiguity by pinning one keychain at a time and
running the *real* `KeychainCredentialStore` through a full round trip — save, load, replace,
reload, delete, confirm-deleted — so a keychain this process cannot use reports itself rather
than handing the question to the next one.

Against the signed Release app:

```bash
InboxSweep.app/Contents/MacOS/InboxSweep --keychain-probe
```

```
PROBE data protection keychain: unavailable (errSecMissingEntitlement (-34018))
PROBE login keychain: round-tripped
PROBE preferred=login keychain
PROBE Credential storage: Login Keychain fallback
```

### Data protection keychain: not available, and here is the number

`errSecMissingEntitlement (-34018)`, exactly as §2 predicts. This is not a failure of the save
and not a bug in the store; it is the wrong keychain for an app signed without a provisioning
profile. **The data protection keychain path could not be verified on this machine**, because
no build this machine can produce has the entitlement it needs. What *is* verified is that the
app detects that condition by its status code rather than by guessing, and reports it.

### Login keychain: full round trip, on the real store

`round-tripped` means all six steps passed, against `KeychainCredentialStore` itself rather
than a mock: save succeeded, the saved value read back byte-identical, a replacement replaced
rather than duplicated, the item was found in the keychain it was written to, deletion
succeeded, and a read after deletion returned nothing. No fallback was involved — the probe was
pinned, so a result from the other keychain was not reachable.

### Where the real credential lives

Existence only; the item's data is never requested, so this cannot print a token even by
accident:

```bash
InboxSweep.app/Contents/MacOS/InboxSweep --keychain-backend
```

```
BACKEND Credential storage: Login Keychain fallback
```

## 4. Same binary, quit and reopened

Build once, run the same `.app` repeatedly with no rebuild in between.

```
cdhash 9e38d286adcdd925cdc3f12bb68102f44416ab71
run 1  SELFCHECK stored   keychain=login keychain
run 2  SELFCHECK restored keychain=login keychain
run 3  SELFCHECK restored keychain=login keychain
```

**Restores**, on the signed Release binary. No prompt, no re-authorization, and the same
keychain both times — a build that had silently changed backends would otherwise look identical
to one that had not.

## 5. Rebuilt and re-signed, then launched

Built again from the same source with the same signing configuration, producing a different
binary, and asked to read the marker the *previous* signed Release build wrote.

```
old cdhash 9e38d286adcdd925cdc3f12bb68102f44416ab71
new cdhash 83bac0ffa419f61729b6896e860ca479ca57aedb
           SELFCHECK restored keychain=login keychain   (marker written by 9e38d286…)
```

**Also restores.** The two builds have byte-different code directories and the *same* designated
requirement, and the requirement is what the login keychain's ACL matches on. So this is stable
signing-identity behaviour, not luck: any build carrying this bundle identifier and this
certificate reads the item.

What would break it, and should: signing with a different certificate or team, or changing
`PRODUCT_BUNDLE_IDENTIFIER`. Either produces a different designated requirement and the stored
item becomes another app's as far as the Keychain is concerned. The app reports that as
`.credentialStoreUnreadable`, not as a silent sign-out.

## 6. Live Gmail round trip

A real Gmail account, read-only, on the signed Release app — the same `.app` throughout, cdhash
`9e38d286adcdd925cdc3f12bb68102f44416ab71`. The sign-in itself was completed by the account
holder in Google's own window; nothing here typed a password.

| Step | Result |
| --- | --- |
| Connect, complete Google OAuth, load live Gmail metadata | 250 messages, 82 senders |
| Which backend stored the refresh credential | `BACKEND Credential storage: Login Keychain fallback` |
| Quit normally, reopen the same `.app` | No Google sign-in or consent window |
| Account identity restored | Yes — the cache file is named for the SHA-256 of the restored address, and the running app matched it |
| Cached dashboard restored | Yes, and the cache file was **not** rewritten on relaunch — the window came from disk, costing no Gmail quota |
| Refresh after restore | **Reload** rewrote the cache, `saved_at` 1789092349 → 1789092609, 250 messages and 82 senders read fresh |
| Proposals recomputed | Structurally — the cache record has no field for a proposal or a verdict, so every launch derives them from the stored metadata |
| Mailbox mutation | None possible: the granted scope is `gmail.metadata`, and no write method exists at the provider boundary. `SafetyBoundaryTests` asserts both |

The refresh is the load-bearing step. It proves the *stored* credential — not a live session — was
exchanged for a new access token and used against Gmail, which is the single thing a
credential store exists to make possible.

### A defect the live run exposed

With a real credential in the Keychain, the UI test for the signed-out screen failed. It
launched the app with no arguments and asserted that the signed-out screen appeared — which is
true only on a Mac that is *not* connected to Gmail. On a connected one the app restored, landed
on the dashboard, and the test run went through the developer's real mailbox.

That is a test asserting on the machine rather than on the app, and it can only be found by
doing what this interval did. The case now launches with `--ignore-stored-credentials`, a
Debug-only argument that swaps the credential store for an empty process-lifetime one. Same
provider, same configuration, same screen under test; the Keychain item is neither read nor
written. Verified afterwards: the full suite passes with the live credential in place, and the
credential and cache are untouched by the run.

### What this run does and does not establish

It establishes that a credential written by this signed Release build, into the login keychain,
survives a normal quit and is usable against Gmail on the next launch of the same binary. It
says nothing about a distribution build, and nothing about the data protection keychain — see
the limitations below.

## Limitations of what was verified

- **Development signing, not distribution signing.** Everything above is an Apple
  Development-signed build carrying `get-task-allow`. A Developer ID or App Store build is
  signed by a different certificate, would not carry that entitlement, and — if it embedded a
  provisioning profile — would use the **data protection keychain** instead of the login
  keychain. None of that has been built or tested here, because no such certificate is
  installed.
- **The data protection keychain path is unexercised.** Its code path exists, is preferred, and
  is skipped for a measured reason (`-34018`). Whether a credential round-trips through it on
  this app has not been demonstrated, and this document does not claim it.
- **Re-signing with a different identity was not tested.** The behaviour described at the end of
  §5 follows from the designated requirement; it was not measured.
- **One machine, one account, one macOS version.** macOS 26.6.2, Xcode 26.6.

## Remaining build output

One line appears in every build and is not a project warning:

```
appintentsmetadataprocessor: warning: Metadata extraction skipped.
No AppIntents.framework dependency found.
```

It is stdout from the `ExtractAppIntentsMetadata` build phase, which Xcode runs for every app
target. It carries no file or line, does not appear as an issue against the project, and does
not affect the build result. Removing it would mean linking `AppIntents.framework` and defining
an App Intent the app has no use for, so it is left alone and recorded here instead.

The `Info.plist in Copy Bundle Resources` warning reported at the end of Interval 4 is **gone**.
Its cause was an empty `InboxSweep/Info.plist` that was simultaneously the target's
`INFOPLIST_FILE` and — because `InboxSweep/` is a file-system-synchronized group — an
automatically added bundle resource. Both the file and the `INFOPLIST_FILE` setting were removed
before this interval; `GENERATE_INFOPLIST_FILE = YES` supplies the Info.plist. A clean Release
build produces no `warning:` line other than the AppIntents note above.

## Reproducing all of it

```bash
# Signed Release build. No CODE_SIGNING_ALLOWED=NO.
xcodebuild -project InboxSweep.xcodeproj -scheme InboxSweep -configuration Release \
  -derivedDataPath build clean build

APP=build/Build/Products/Release/InboxSweep.app

codesign -dvvv "$APP"                              # identity, team, cdhash, runtime flags
codesign -d --entitlements - --xml "$APP" | plutil -p -
codesign -d -r- "$APP"                             # designated requirement
ls "$APP/Contents/embedded.provisionprofile"       # absent on this configuration

"$APP/Contents/MacOS/InboxSweep" --keychain-probe          # per-keychain, no fallback
"$APP/Contents/MacOS/InboxSweep" --keychain-backend        # where the real credential is
"$APP/Contents/MacOS/InboxSweep" --keychain-selfcheck      # run twice: stored, then restored
"$APP/Contents/MacOS/InboxSweep" --keychain-selfcheck-reset
```

Every one of these modes is inert without its launch argument, reaches no UI, and prints no
token, refresh token, authorization code, or client secret. The probes write synthetic markers
under diagnostic-only Keychain services and delete them;
`CredentialStoreDiagnosticsTests` asserts both the cleanup and the absence of secrets in the
output.

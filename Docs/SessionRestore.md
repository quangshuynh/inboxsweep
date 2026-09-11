# Session restore

How InboxSweep remembers a sign-in between launches, what it stores where, and — because the
two are easy to confuse — what was actually measured versus what is merely expected.

---

## The defect this document exists because of

Through Interval 3, InboxSweep appeared to sign itself out on every relaunch. The working
hypothesis was that re-signing the app during development changed Keychain access.

**That hypothesis was wrong.** The refresh token was never stored at all, on any launch.

### What was actually happening

`KeychainCredentialStore` passed `kSecUseDataProtectionKeychain: true`. The data protection
keychain scopes every item to a *keychain access group*, which an app derives from its
`keychain-access-groups` entitlement or, failing that, its `com.apple.application-identifier`
entitlement.

InboxSweep has neither. A macOS app whose only capabilities are App Sandbox and outgoing
network is signed without a provisioning profile, and the entitlements on the built app are
exactly:

```
com.apple.security.app-sandbox
com.apple.security.get-task-allow
com.apple.security.network.client
```

No access group, so no data-protection write can succeed. Measured from inside the app process:

| Operation | `kSecUseDataProtectionKeychain` | Result |
| --- | --- | --- |
| `SecItemAdd` | `true` | `errSecMissingEntitlement` (**-34018**) |
| `SecItemCopyMatching` | `true` | `errSecItemNotFound` (**-25300**) |
| `SecItemAdd` | absent | `errSecSuccess` (0) |
| `SecItemCopyMatching` | absent | `errSecSuccess` (0) |

Two pieces of error handling then hid it completely:

- `GmailProvider.connect()` wrote the credential with `try? credentialStore.save(...)`. The
  `-34018` was discarded. Sign-in looked perfect.
- `GmailProvider.restoreConnection()` read it with `(try? credentialStore.load()) ?? nil` and
  treated `nil` as "no account" — the same answer a genuine first launch produces.

So the app signed out on *every* relaunch, rebuilt or not. The correlation with rebuilding was
coincidental: a developer only relaunches after rebuilding.

### Why the existing tests were green

Every credential test ran against `InMemoryCredentialStore`. No `SecItem*` call was ever made by
a test, so no test could observe a Keychain that refused every write.

---

## How it works now

`KeychainCredentialStore` consults both of macOS's keychains, in preference order, and uses the
first one *this process can actually use*:

1. **Data protection keychain** — preferred. App-scoped by the system rather than by an ACL.
   Available to a build signed with a provisioning profile that grants an application-identifier
   or keychain-access-groups entitlement.
2. **Login (file) keychain** — the fallback. Reachable by any signed app for its own items,
   protected by the login keychain and an ACL naming this app.

A save writes to exactly one of them and deletes any copy left in the other, so a build that
gains the data protection keychain does not leave a stale refresh token behind.

The distinction that matters is between a keychain this process **cannot use** and one that
**refuses**:

| Status | Meaning | Behaviour |
| --- | --- | --- |
| `errSecItemNotFound` | Nothing stored here | Try the next keychain; ultimately `nil` |
| `errSecMissingEntitlement`, `errSecNotAvailable` | Wrong keychain for this process | Skip it |
| `errSecAuthFailed`, `errSecInteractionNotAllowed`, `errSecInteractionRequired`, `errSecUserCanceled` | Refused | `CredentialStoreError.accessDenied` |
| `errSecDecode`, `errSecInvalidData`, or undecodable JSON | Stored bytes unusable | Discarded, reported as `.malformedStoredData` |
| anything else | — | `.unhandled(status)` |

### What is stored

Only `GmailStoredCredentials`: the refresh token, the granted scopes, and the account address.
Access tokens are never persisted — they last about an hour and are cheap to re-obtain, so
storing them would add exposure for no benefit.

Accessibility on the data protection keychain is `kSecAttrAccessibleAfterFirstUnlock`: the token
is needed at launch without the user present, and never needed while the device is locked. That
attribute is not meaningful on the file keychain and is not set there.

### What a failure looks like now

`MailRestoreOutcome` has three cases rather than two, so the app can tell a first launch from a
failed restore:

- `.noStoredCredentials` — nothing stored. Signed-out screen, silently. The ordinary case.
- `.restored(account)` — a working connection.
- `.unusable(failure)` — something was stored and could not be used. The signed-out screen, plus
  a `SessionNotice` saying which of *revoked*, *scopes changed*, *unreadable*, or *malformed*
  applies. A provider outage instead gets an error screen with **Try again**, because retrying is
  the right move and re-authorizing is not.

`StoredAuthorizationState` covers the other half: a sign-in that succeeded but could not be
**saved** now shows a notice immediately, while the user is still there to read it, instead of
being discovered as an unexplained signed-out screen next launch.

No error message, notice, or log line contains a refresh token, an access token, or any part of
one. `KeychainCredentialStoreTests` asserts this.

---

## Measured behaviour

Two different things, tested separately, because they are not the same test.

Reproduce either with the debug-only self-check, which writes a synthetic marker under its own
Keychain service, reports what it found, and exits:

```bash
InboxSweep.app/Contents/MacOS/InboxSweep --keychain-selfcheck
```

`--keychain-selfcheck-reset` removes the marker. Debug builds only; no UI reaches it.

### A. Same binary, quit and reopened

Build once, run the same `.app` repeatedly with no rebuild in between.

```
cdhash ecb2e9973d0fc75027b95e3543535b4589f96b98
run 1  SELFCHECK stored   keychain=login keychain
run 2  SELFCHECK restored keychain=login keychain
run 3  SELFCHECK restored keychain=login keychain
```

**Restores.** No prompt, no re-authorization.

### B. Rebuilt and re-signed, then launched

Change a source file, rebuild, re-sign, run the *new* binary.

```
cdhash df7b2f8e58e542d9e5b33c4efe99d421ea55f65c   (different binary)
run 4  SELFCHECK restored keychain=login keychain   (marker written by cdhash ecb2e997…)
```

**Also restores.** Development re-signing does not break Keychain access, which is what
disproves the original hypothesis.

The mechanism is visible in the app's designated requirement:

```
identifier "quang.InboxSweep" and anchor apple generic
  and certificate leaf[subject.CN] = "Apple Development: … (T5G5R8V962)"
  and certificate 1[field.1.2.840.113635.100.6.2.1] exists
```

It pins the **bundle identifier and the signing certificate**, not the code directory hash. A
rebuild changes the cdhash and leaves the requirement intact, so the ACL still matches.

What *would* break it: signing with a different certificate or team, or changing
`PRODUCT_BUNDLE_IDENTIFIER`. Both produce a different designated requirement, and the stored
item becomes another app's as far as the Keychain is concerned. That is correct behaviour, and
the app reports it as `.credentialStoreUnreadable` rather than as a silent sign-out.

### What has *not* been verified

- **Distribution builds.** Everything above was measured on a locally signed development build
  with an Apple Development certificate. A Developer ID or App Store build carries a
  provisioning profile, would use the **data protection keychain** instead, and has not been
  built or tested here. The fallback exists precisely so that the code path is the same either
  way, but "production Keychain persistence is proven" is not a claim this document makes.
- **Keychain prompts under a changed signing identity.** Not exercised; re-signing with a
  *different* certificate was not tested.

---

## Local cache restoration

The credential store answers *who*; `FileInboxCacheStore` answers *what was loaded*.

- One JSON file per account, named by a SHA-256 digest of the address, inside the sandboxed
  container's Application Support directory. Owner-only permissions, excluded from backups.
- At most one account's window is kept. Saving a second account's window deletes the first.
- A cached window is only ever shown **after** a credential restore succeeds, and only for the
  account that restore produced. A restore that fails shows no cache at all — personal mail is
  never displayed without the authenticated account it belongs to.
- The file records the account address it was written for, and a window whose address does not
  match the restored account is discarded rather than shown.
- Proposals are never cached. They are recomputed from the stored metadata on every launch, so a
  rules change takes effect immediately instead of leaving last week's verdicts on screen.
- A restored window is labelled as one in the header, with how old it is. **Reload** replaces it
  with a fresh read.
- Disconnecting deletes the file and the Keychain item.

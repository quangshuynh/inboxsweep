# Connecting Gmail

InboxSweep needs its own Google OAuth client. The client belongs to your Google Cloud project,
so it is not committed to this repository: you create one once and point the app at it.

!!! info "Nothing here is a client secret"

    InboxSweep uses an **iOS/macOS** OAuth client, which Google issues **without a secret**, and
    protects the sign-in with PKCE instead. If you find yourself copying a client secret into
    this project, you have created the wrong client type.

## The permissions it asks for

Two scopes, and no others:

```
https://www.googleapis.com/auth/gmail.metadata   read headers, labels, and dates
https://www.googleapis.com/auth/gmail.modify     change which labels a message carries
```

`gmail.metadata` is deliberately narrower than the more common `gmail.readonly`, which would
also hand the app every message body.

!!! warning "`gmail.modify` is broader than what the app does with it"

    That scope would also permit trashing messages, marking them read, applying arbitrary
    labels, and reading bodies. Google publishes nothing narrower that can archive:
    `gmail.labels` governs label *definitions*, not applying them to a message. The alternative
    is not a smaller permission; it is not having an archive feature at all.

    So the restraint lives in the code and its tests rather than in the grant, and the app's
    signed-out screen says so **before** sending you to Google, rather than letting the consent
    screen contradict the app. Someone auditing the grant in their Google Account will see a
    broad permission and cannot see the app's limits from there. What those limits are, and how
    they are tested, is in [Privacy and security](privacy-and-security.md).

InboxSweep never requests `https://mail.google.com/` (the full-access scope, and the only one
that permits **permanent deletion**), nor `gmail.send`, `gmail.compose`, `gmail.insert`,
`gmail.labels`, `gmail.settings.*`, or contacts.

One practical consequence of `gmail.metadata`: Gmail rejects search queries (`q=`) under it.
The fetch layer works within that limit, and still requests `format=metadata` with named
headers even though `gmail.modify` would now permit bodies.

## 1. Create a Google Cloud project

1. Open the [Google Cloud console](https://console.cloud.google.com/) and create a project, or
   pick an existing one.
2. Under **APIs & Services → Library**, enable the **Gmail API**.

## 2. Configure the consent screen

1. Go to **APIs & Services → OAuth consent screen**.
2. Choose **External**, unless your account belongs to a Google Workspace organisation.
3. Fill in the app name and support email.
4. Under **Scopes**, add both of the scopes listed above. Adding only `gmail.metadata` produces
   a working sign-in whose Archive control then asks for the second permission separately,
   which is a supported path but a confusing one to start from.
5. Add your own Google account under **Test users**.

`gmail.metadata` and `gmail.modify` are both *restricted* scopes. While your client stays in
**Testing**, only the accounts you list as test users can sign in, which is all a development
setup needs. Publishing to production would require Google's verification process.

## 3. Create the OAuth client

1. Go to **APIs & Services → Credentials → Create credentials → OAuth client ID**.
2. Choose application type **iOS**. That is the correct type for a macOS app signing in through
   a custom URL scheme; Google publishes no separate macOS option.
3. Enter the app's bundle identifier. For an unmodified checkout that is `quang.InboxSweep`. If
   you changed `PRODUCT_BUNDLE_IDENTIFIER` in the Xcode project, use your value.
4. Download the generated property list.

## 4. Point InboxSweep at the client

Either option works. The environment variable takes precedence.

=== "Property list (recommended)"

    Rename the downloaded file to `GoogleOAuthClient.plist` and put it at:

    ```
    InboxSweep/Config/GoogleOAuthClient.plist
    ```

    Create the `Config` directory if it does not exist. Xcode's file-system-synchronized group
    picks the file up and copies it into the app bundle with no project changes. **The whole
    directory is gitignored**, and a check in CI fails the build if anything under it is ever
    committed.

    To write the file by hand, [`GoogleOAuthClient.example.plist`](examples/GoogleOAuthClient.example.plist)
    is a template. Only `CLIENT_ID` is required; `REVERSED_CLIENT_ID` is derived from it when
    absent.

=== "Environment variable"

    Useful when running from Xcode. Edit the **InboxSweep** scheme → **Run** → **Arguments** →
    **Environment Variables** and add:

    ```
    INBOXSWEEP_GOOGLE_CLIENT_ID = YOUR-CLIENT-ID.apps.googleusercontent.com
    ```

## 5. Verify the round trip

No step below changes your mailbox.

1. **Sign in.** Launch the app and click **Connect Gmail**. Google's own window opens, in an
   ephemeral browser session. If the client ID or redirect URI is wrong, this fails on Google's
   side with `invalid_client` or `redirect_uri_mismatch` before any prompt appears.
2. **Read the consent screen.** It should ask for those two things and nothing else. An
   unverified client also warns that the app is in testing, which is expected.
3. **Token exchange.** Granting consent should land you on the sender dashboard within a few
   seconds.
4. **Restoration.** Quit and relaunch. The dashboard should come back immediately, labelled as
   restored from this Mac, with no Gmail request: that is the Keychain refresh token plus the
   local cache. **Reload** fetches current mail.
5. **Sign out.** **Disconnect** revokes the grant, removes the Keychain item, and deletes the
   local files. Confirm the Keychain item is gone with:

   ```bash
   security find-generic-password -s "InboxSweep.Gmail" -a default
   ```

   which should report that the item could not be found. The app should also disappear from
   your [Google Account's third-party apps page](https://myaccount.google.com/connections).

## Where each value lives

| Value | Where it lives | Committed |
| --- | --- | --- |
| Client ID | `InboxSweep/Config/GoogleOAuthClient.plist`, or an environment variable | No: gitignored |
| Your Google password | Typed into Google's own window. InboxSweep never sees it | No |
| Refresh token | macOS Keychain, item `InboxSweep.Gmail` | No |
| Access token | Memory only, for the life of the process | No |
| Message metadata | Memory while running, plus one JSON file in the app's sandbox container | No |

What that JSON file holds, and what it cannot hold, is in
[Privacy and security](privacy-and-security.md#what-is-stored-on-this-mac).

## If you signed in before archiving existed

A read-only grant keeps working and is not treated as broken. The Archive control becomes
**Enable archiving…**, which asks for the extra permission and nothing else. Declining leaves
the session exactly as it was; granting persists the widened scope, keeping the refresh token
Google does not reissue.

## Sign-in that cannot be restored

A failed restore is not the same as a first launch, and the app does not let the two produce
the same silent signed-out screen. `MailRestoreOutcome` has three cases rather than two, so
"nothing was stored" and "the Keychain refused us" are distinguishable, which is how a
credential-persistence bug survived an entire development interval before this distinction
existed. The diagnostics for checking which case you are in are in
[Testing](testing.md#checking-that-a-sign-in-survives-a-relaunch).

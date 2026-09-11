# Google OAuth setup

InboxSweep needs its own Google OAuth client to sign in. The client is tied to your Google
Cloud project, so it is not committed to this repository — you create one once and point the
app at it.

Nothing you create here is a secret in the usual sense: InboxSweep uses an **iOS/macOS**
OAuth client, which Google issues **without a client secret**, and protects the sign-in with
PKCE instead. If you find yourself copying a client secret into this project, you have
created the wrong client type.

## 1. Create a Google Cloud project

1. Open the [Google Cloud console](https://console.cloud.google.com/) and create a project
   (or pick an existing one).
2. Under **APIs & Services → Library**, enable the **Gmail API**.

## 2. Configure the consent screen

1. Go to **APIs & Services → OAuth consent screen**.
2. Choose **External** unless your account is part of a Google Workspace organisation.
3. Fill in the app name and support email.
4. Under **Scopes**, add exactly one scope:

   ```
   https://www.googleapis.com/auth/gmail.metadata
   ```

   This is a *restricted* scope. While your app is in **Testing**, only accounts you list
   under **Test users** can sign in — which is all you need for development. Publishing to
   production would require Google's verification process.
5. Add your own Google account under **Test users**.

## 3. Create the OAuth client

1. Go to **APIs & Services → Credentials → Create credentials → OAuth client ID**.
2. Choose application type **iOS** (this is the correct type for a macOS app that signs in
   with a custom URL scheme; there is no separate macOS option).
3. Enter the app's bundle identifier. For an unmodified checkout that is:

   ```
   quang.InboxSweep
   ```

   If you change `PRODUCT_BUNDLE_IDENTIFIER` in the Xcode project, use your value instead.
4. Download the generated `.plist`.

## 4. Point InboxSweep at the client

Either option works; the environment variable takes precedence.

### Option A — drop in the property list (recommended)

Rename the downloaded file to `GoogleOAuthClient.plist` and put it here:

```
InboxSweep/Config/GoogleOAuthClient.plist
```

Create the `Config` directory if it does not exist. Xcode's file-system-synchronized group
picks the file up automatically and copies it into the app bundle — no project changes are
needed. The path is gitignored.

If you would rather write the file by hand, `Docs/GoogleOAuthClient.example.plist` is a
template. Only `CLIENT_ID` is required; `REVERSED_CLIENT_ID` is derived from it when absent.

### Option B — set an environment variable

Useful when running from Xcode. Edit the **InboxSweep** scheme → **Run** → **Arguments** →
**Environment Variables** and add:

```
INBOXSWEEP_GOOGLE_CLIENT_ID = YOUR-CLIENT-ID.apps.googleusercontent.com
```

## 5. Verify

Launch the app. The signed-out screen should show a **Connect Gmail** button rather than the
"Google sign-in isn't set up yet" notice. Clicking it opens Google's own sign-in window; the
consent screen should ask for the two permissions in [Docs/Archiving.md](Archiving.md) and
nothing else.

## What gets stored where

| Value | Where it lives | Committed? |
| --- | --- | --- |
| Client ID | `InboxSweep/Config/GoogleOAuthClient.plist` or an environment variable | No — gitignored |
| Refresh token | macOS Keychain, item `InboxSweep.Gmail` | No |
| Access token | Memory only, for the life of the process | No |
| Message metadata | Memory while the app runs, plus one JSON file in the app's sandbox container | No |

The metadata file lives at
`~/Library/Containers/quang.InboxSweep/Data/Library/Application Support/InboxSweep/Cache/`
and holds message headers, dates, and labels — never bodies, and never a token of any kind.
The README's [Local persistence](../README.md#local-persistence) section lists exactly what it
contains.

Signing out from within the app asks Google to revoke the grant, deletes the Keychain item,
and deletes that file. You can also revoke access at any time from your
[Google Account's third-party apps page](https://myaccount.google.com/connections).

## Checking a live sign-in

Once a client is configured, this is the round trip worth walking through by hand. No step
below changes your mailbox: archiving is a separate, explicitly confirmed action, described in
[Docs/Archiving.md](Archiving.md).

1. **Sign in.** Launch the app and click **Connect Gmail**. Google's own window opens.
2. **Read the consent screen.** It should ask for two things and nothing else: read access to
   Gmail *metadata*, and permission to change which labels a message carries. Google describes
   the second one far more broadly than what InboxSweep does with it — the app's signed-out
   screen explains that before sending you here, and the only labels it can change are `INBOX`
   on one message you confirm. An unverified client also warns that the app is in testing,
   which is expected while the client stays in Testing mode.
3. **Token exchange.** Granting consent should land you on the sender dashboard within a few
   seconds. That means the authorization code was exchanged for tokens successfully.
4. **Restoration.** Quit and relaunch. The dashboard should come back immediately, labelled
   as restored from this Mac, without a Gmail request — that is the Keychain refresh token
   plus the local cache. **Reload** fetches current mail.
5. **Sign out.** **Disconnect** revokes the grant with Google, removes the Keychain item, and
   deletes the cache file. Confirm with:

   ```bash
   security find-generic-password -s "InboxSweep.Gmail" -a default
   ```

   which should report that the item could not be found, and check that the cache directory
   above is empty. The app should also disappear from your
   [Google Account's third-party apps page](https://myaccount.google.com/connections).

If the client ID or the redirect URI is wrong, step 1 fails on Google's side with
`invalid_client` or `redirect_uri_mismatch` before any sign-in prompt appears.

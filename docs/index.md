---
hide:
  - navigation
---

<p align="center">
  <img src="images/inboxsweep-logo.png" alt="InboxSweep" width="160">
</p>

<h1 align="center">InboxSweep</h1>

<p align="center"><strong>A privacy-conscious Gmail cleanup assistant for macOS.<br>
It recommends; you authorize.</strong></p>

---

InboxSweep reads your Gmail **metadata**, groups it by sender, says which senders look worth
cleaning up and why, and shows what a cleanup *would* affect before anything happens. Mail
bodies are never requested, nothing is ever deleted, and no recommendation can carry itself
out.

It is a native SwiftUI app. There is no server, no account, no analytics, and no AI: the only
network destination it has other than Google's own API is a sender's unsubscribe endpoint, and
only when you confirm it.

## What it can change

InboxSweep can do exactly three things to a mailbox. Each one is on its own page, because each
one is a promise worth reading in full.

<div class="grid cards" markdown>

-   :material-archive-outline: **[Archive messages you selected](archive-and-undo.md)**

    Removes the `INBOX` label from messages you ticked and confirmed as a list, one request at
    a time. Archiving is not deleting. Undo is a real Gmail request and survives quitting the
    app.

-   :material-email-off-outline: **[Send one unsubscribe request](unsubscribe.md)**

    Reads the `List-Unsubscribe` headers the sender wrote, shows the exact destination, and
    acts only after you confirm. A request is not a guarantee that the sender honours it, and
    the app says so before you decide.

-   :material-shield-key-outline: **[Run a sender rule you authorized](rules.md)**

    One exact address, one action, and only while the app is loading mail. A rule does nothing
    while InboxSweep is closed. It is not a Gmail filter and cannot become one.

</div>

## What it will not do

<div class="grid cards" markdown>

-   :material-delete-off-outline: **Nothing is deleted**

    No delete, no trash, no permanent removal. The app never requests a scope that would permit
    it. See [Privacy and security](privacy-and-security.md).

-   :material-robot-off-outline: **No AI, no analytics, no telemetry**

    No message, header, or subject is sent to any classifier or any third party. There is no
    third-party runtime dependency of any kind.

-   :material-sleep: **Nothing runs in the background**

    No scheduler, no daemon, no notifications. Every change happens while you have the app
    open, and rules are no exception.

-   :material-cursor-default-click-outline: **No proposal executes itself**

    A recommendation can pre-tick checkboxes. You still read the list, edit it, open a
    confirmation, and press the button. See [Cleanup proposals](cleanup-proposals.md).

</div>

## Where to start

| If you want to | Read |
| --- | --- |
| Build and run it | [Install and run](getting-started.md) |
| Connect a real Google account | [Connecting Gmail](gmail-integration.md) |
| Understand the recommendations | [Cleanup proposals](cleanup-proposals.md) |
| Know exactly what a write does | [Archiving and undo](archive-and-undo.md) |
| Audit the privacy claims | [Privacy and security](privacy-and-security.md) |
| See how the code is arranged | [Architecture](architecture.md) |
| Know what it cannot do | [Limitations](limitations.md) |

## Status

macOS only, built with SwiftUI and Swift 6, requiring macOS 26.5 and Xcode 26.6. It is a
personal project rather than a shipping product: there is no notarized build, no release, and
no independent security audit. What the documentation claims is what the code and its tests
actually do, and [Limitations](limitations.md) is a first-class page rather than a footnote.

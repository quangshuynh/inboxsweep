# Unsubscribing

InboxSweep can send **one** unsubscribe request, to the destination the sender itself published
in its headers, after you confirm it twice.

!!! warning "A request is not a completed unsubscription"

    InboxSweep sends the request. Whether the sender honours it, how long that takes, and whether
    mail actually stops are entirely the sender's to decide. The app records that a request was
    sent and never claims more than that.

!!! warning "Unsubscribing cannot be undone"

    Unlike [archiving](archive-and-undo.md#undo), there is no undo. The app says so before you
    decide, on the confirmation itself.

## Archiving and unsubscribing are different things

| | Archiving | Unsubscribing |
| --- | --- | --- |
| What it touches | Mail already in your Inbox | Mail that has not arrived yet |
| Where it goes | Google's API | The sender's own host, or your browser, or your mail app |
| Reversible | Yes, one transaction per account | **No** |
| Guaranteed | Yes, Gmail confirms each message | **No**, it is a request to a third party |

They are separate capabilities on separate boundaries, and doing one never does the other.

## What counts as an unsubscribe opportunity

Only two headers, both written by the sender:

```
List-Unsubscribe:       <https://lists.example/u/abc>, <mailto:unsub@lists.example>
List-Unsubscribe-Post:  List-Unsubscribe=One-Click
```

That is the whole of the evidence. Specifically **not** evidence: a link in a message body, which
the app never fetches; a phrase in a subject line; the sender's Gmail category; or a guess based
on the shape of an address.

## The five states

A sender's unsubscribe reading is one of five, and the interface distinguishes all of them rather
than collapsing "we do not know" into "no".

| State | Meaning |
| --- | --- |
| **No option** | No loaded message from this sender carried the header |
| **Details unclear** | The header is present but could not be parsed into anything actionable |
| **One-click** | `List-Unsubscribe-Post` declares RFC 8058 one-click, with an HTTPS target |
| **A page** | An HTTPS target with no one-click declaration: this needs your browser |
| **An email request** | Only a `mailto:` target: this needs your mail app |

The reading is scoped to the loaded window, like every other observation. A sender whose recent
mail carries no header may still have sent some that does.

## Parsing

The parser reads the angle-bracket list the RFCs define, keeps the order the sender wrote, and
sorts what it finds into HTTPS targets and `mailto:` targets.

- `http://` targets are **rejected**, not upgraded. Silently promoting a sender's plaintext URL to
  HTTPS would be inventing a destination they did not publish.
- A target that is neither HTTPS nor `mailto:` is dropped.
- **Contradictory metadata is not resolved by guessing.** A `List-Unsubscribe-Post` declaring
  one-click with no HTTPS target to post to is not a one-click opportunity, and the app says the
  details are unclear rather than picking something to do.

## Which mechanism is offered

One-click is offered when, and only when, the sender declared it and published an HTTPS target for
it. Otherwise the browser handoff is offered where there is an HTTPS target, and the mail handoff
where there is only a `mailto:`. When a sender published several, the sheet shows them and you
choose.

## What each action actually does

=== "One-click"

    A single `POST` to the sender's HTTPS target with the body RFC 8058 defines.

    The transport is **separate from the Gmail one and has never held a credential**. The request
    carries no `Authorization` header, no cookie, no Google token, and nothing about your mailbox.
    A test connects a real provider, mints a token, and proves none of it appears in what the
    unsubscribe request carried.

    The result is reported as what it is: the sender's host answered, or it did not.

=== "Browser handoff"

    Opens the sender's HTTPS page in your default browser and stops there. InboxSweep does not
    fetch the page, does not fill in a form, and does not follow what happens next. Whatever the
    page then asks of you is between you and the sender.

=== "Mail handoff"

    Opens a prepared message in your mail app, addressed as the sender's `mailto:` target
    specifies. **It does not send it.** You do, or you do not. InboxSweep holds no permission to
    send mail and requests no scope that would allow it.

In all three cases the exact destination is printed before you confirm.

## Redirect policy

A one-click `POST` follows redirects only under a deliberately narrow rule: the redirect must stay
on HTTPS, and the number of hops is bounded. A redirect to `http://` or to a scheme the policy
does not recognise ends the request rather than being followed.

The reason is that a redirect chain is the sender's to control, and an unbounded follow turns
"post to the address they published" into "go wherever they send you".

## Retries

**There are none.** A one-click request is sent once. If it fails, the app says it failed and
leaves the decision to you, because a retry that the sender counts twice is worse than a failure
you can see.

## What the app says afterwards

The result is stated in terms of the request, not the outcome. The sender's host accepted the
request, or it refused, or it could not be reached. Nothing in the app claims you have been
unsubscribed, because nothing in the app can know that.

Mail from the sender may keep arriving for a while, and that is normal rather than a failure.

## Confirmation and staleness

A confirmation names the sender, the mechanism, and the exact destination. It is frozen the same
way an [archive confirmation](archive-and-undo.md#the-set-is-frozen) is: what you read is what
gets sent.

A previously recorded opportunity that no longer matches the loaded window is treated as stale and
re-derived rather than acted on, and a sender you have already sent a request to is marked as such
so you do not send a second one by accident.

## In Activity

An unsubscribe appears in [Activity](activity.md) as what it was: a request of a given kind to a
given sender, at a given time, with the answer the host gave. It is never listed as undoable,
because it is not.

## Limitations

- The app reads only what the sender published. A sender who publishes nothing offers nothing to
  act on, and the only route is the link in the message, which InboxSweep cannot see.
- One-click's success means the host accepted the request. It does not mean a human or a system at
  the other end has acted on it.
- The browser and mail handoffs end at the handoff. Whether you finished the flow is not something
  the app can observe, so it records that it opened the destination and no more.
- There is no bulk unsubscribe, no automatic unsubscribe, and no rule that unsubscribes. Every
  request is one sender at a time, confirmed by you.

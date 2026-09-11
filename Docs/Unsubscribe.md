# Unsubscribing

InboxSweep can find the unsubscribe mechanism a sender declared in their own message headers,
show you exactly where it goes, and — after you confirm it twice — carry out one of three
tightly bounded actions.

It cannot unsubscribe you from anything on its own. There is no automatic unsubscribe, no bulk
unsubscribe, no background retry, and no rule, filter, or block. Every unsubscribe in this app
begins with a person reading a destination and pressing a button about it.

**The governing rule:** InboxSweep may detect and explain unsubscribe opportunities. Only you
can authorize one.

---

## Archiving and unsubscribing are different things

This is the distinction the whole feature is built around, and the app says it on every screen
where the two appear together.

| | Archive | Unsubscribe |
| --- | --- | --- |
| What it affects | Messages already in your mailbox | Mail that has not been sent yet |
| Where the request goes | Gmail | The sender's own server, or your browser, or your mail app |
| What authorizes it | Your Google OAuth grant | Nothing but a header the sender wrote |
| Can it be undone? | Yes — a real request putting the messages back | **No.** There is no standard reverse |
| Does it change a message? | Yes, one label on each | No message changes at all |

> Archiving changes messages you already have. Unsubscribing is about messages you haven't
> received yet: it asks the sender to stop sending. It doesn't remove, move, or change a single
> message already in your mailbox, and InboxSweep can't undo it.

That sentence lives in one place — `UnsubscribeOpportunity.futureMailNote` — so every screen
that makes the promise makes it in identical words.

---

## What counts as an unsubscribe opportunity

Only what the mail itself declared. InboxSweep reads two headers:

- `List-Unsubscribe` (RFC 2369) — a comma-separated list of bracketed URLs;
- `List-Unsubscribe-Post` (RFC 8058) — which, with the exact value
  `List-Unsubscribe=One-Click`, marks the HTTPS entry as a one-click endpoint.

Both are already covered by the `gmail.metadata` scope the app has always requested. Adding
`List-Unsubscribe-Post` was a change to the *shape* of the metadata request and not to any
permission — see [Gmail access](#gmail-access).

### What is not evidence

- **Subject wording.** A message titled "Newsletter" is not evidence of an unsubscribe
  mechanism. Nothing in the detection rules reads a subject line.
- **Recurrence on its own.** A sender that arrives every day for a month with no
  `List-Unsubscribe` header reaches "no unsubscribe option", not a guess. That rule is what
  keeps a daily bank notice from being read as a mailing list.
- **Message bodies.** InboxSweep never requests them and has nowhere to put one. A sender whose
  only unsubscribe link is in the text of the email is one InboxSweep cannot see — and the
  options screen says so.

Gmail's own bulk categories and a sender's cadence appear as *corroborating* evidence. Neither
can establish an opportunity on its own, and neither can raise how sure the app claims to be.

---

## The five states

There is no `isSubscription` Boolean anywhere in the app. A Boolean would answer a question
nobody is asking; these five are the answers that matter.

| State | What it means | What you can do |
| --- | --- | --- |
| **No unsubscribe option** | No loaded message from this sender carried the header | Nothing. The screen explains that a body link would be invisible to InboxSweep |
| **Unsubscribe details unclear** | A header was there and nothing usable came out of it | Nothing. InboxSweep will not guess at what was meant |
| **One-click unsubscribe** | Both headers agreed: an HTTPS URL plus the RFC 8058 declaration | InboxSweep sends one standard request |
| **Unsubscribe page** | An HTTPS URL with no one-click declaration | Your browser opens it |
| **Email unsubscribe** | A `mailto:` address | Your mail app opens a prepared message |

"A header was present but unusable" is deliberately distinct from "no header". Telling you a
sender offers nothing when they in fact sent something InboxSweep refused would be a different
and untrue statement.

### How sure

A named band, never a number:

| Band | When |
| --- | --- |
| **No evidence** | Nothing found |
| **Unclear** | Something was declared and cannot be used, or this sender's own messages disagree about what it is |
| **From this sender's own header** | A well-formed destination the sender named |
| **Standards-based** | An RFC 8058 one-click endpoint, where the request is specified rather than inferred |

Even the top band is a claim about the *mechanics*, not about the sender's honesty.

---

## Parsing

Header values are sender-controlled text, and acting on one means contacting a third party. So
the text is parsed once, at the provider boundary, into typed values — and nothing above that
boundary can rebuild a destination from a string.

`HTTPSUnsubscribeURL` and `MailtoUnsubscribeAddress` each have a failable initializer that
refuses anything that is not the scheme it names. The one-click request's initializer takes an
`HTTPSUnsubscribeURL`, not a `URL` — so "could the app post to an `http://` or `javascript:`
destination?" is answered by whether such a value can be constructed at all. It cannot.

| Input | Result |
| --- | --- |
| `<https://lists.example/u>` | Web destination |
| `<mailto:leave@lists.example?subject=unsubscribe>` | Mail destination, subject carried for your mail app to prefill |
| `<https://a.example/u>, <mailto:b@a.example>` | Both, in header order |
| `https://lists.example/u` (no brackets) | **Refused.** RFC 2369 requires them, and the bracket is the only thing separating a declared URL from stray text |
| `<http://lists.example/u>` | **Refused.** Never upgraded to `https` — that would be inventing a destination the sender did not name |
| `<javascript:…>`, `<file:…>`, `<data:…>`, custom schemes | **Refused** |
| `<HTTPS://Lists.Example/u>`, folded whitespace | Parsed. Real mail varies like this |
| The same URL twice | Collapsed to one, so a sheet cannot list one destination twice |
| `https://lists.example/u?ids=1,2,3` | One value — splitting happens only on commas outside brackets |
| More than 10 values | Bounded. The first ten are kept |

### Contradictory metadata

`List-Unsubscribe-Post` with no HTTPS URL to apply to is contradictory, and is neither honoured
nor hidden: there is no one-click endpoint, the contradiction is shown as evidence, and whatever
*is* usable — a mail address, say — is still offered.

---

## Which mechanism is offered

Deterministic, and never silent.

1. Standards-based one-click HTTPS
2. Ordinary HTTPS unsubscribe page
3. `mailto` handoff

Ties inside each tier are broken by **header order** — the first value the sender listed. Not
shortest, not by host, not by which looks more official; header order is the only ordering the
sender actually expressed.

The review sheet lists every other mechanism the sender offered alongside the one it chose,
explains why it chose that one, and lets you switch. Switching re-freezes the review with a new
identifier, so a confirmation already spent on one destination cannot be reused for another.

---

## What each action actually does

### One-click

The only case in which InboxSweep itself contacts anybody.

```
POST <the exact URL from the header>
Content-Type: application/x-www-form-urlencoded

List-Unsubscribe=One-Click
```

That is the whole request. What is *not* in it is the feature:

- **No `Authorization` header.** The one-click client has never been given a Google access
  token, has no parameter to receive one, and shares no object with the Gmail API client that
  holds one. `GmailProvider` vends *itself* as the archiver and a *separate type* as the
  unsubscriber, precisely so this is a property of the object graph rather than of a guard.
- **No cookies.** Ephemeral session, cookie storage disabled, `httpShouldHandleCookies` off on
  the request as well — two independent places would have to change.
- **No mailbox content.** No message identifier, no subject, no sender address, not your own
  address. The body is a constant, so a payload cannot be assembled from anything in memory.
- **No added query parameters.** The URL is used byte for byte. A tracking token the sender put
  in their own link is theirs; one InboxSweep appended would be InboxSweep telling a stranger
  something about you.

### Browser handoff

InboxSweep opens the URL with your default browser and stops. It does not fetch the page, parse
it, submit a form, fill in account details, bypass a login or CAPTCHA, or follow redirects to
simulate a person. What the page asks for is between you and that site — and the sheet says so
before you press anything.

### Mail handoff

InboxSweep opens a message in your mail app, addressed, with the subject the header asked for.
**It does not send it.** It cannot: the app holds no Gmail send or compose scope, both are on
the prohibited list, and there is no outbound-mail code anywhere in it.

Only `https` and `mailto` URLs are ever handed to the system. Everything else — `http`
included — is refused by `UnsubscribeHandoff` before an opener sees it.

---

## Redirect policy

`URLSession` follows redirects by default: up to twenty, across schemes, converting `POST` to
`GET` on the way, inside `data(for:)` where nothing can observe it. For a Gmail call that is
fine. For a `POST` to a URL a stranger put in a mail header it is not.

So redirects are refused at the session delegate and handled explicitly instead:

| Response | What happens |
| --- | --- |
| 2xx | The request was accepted |
| **307, 308** | Followed — these re-send the same `POST` with the same body |
| **301, 302, 303** | **Not followed.** Each means "do a `GET` instead", which is not the request RFC 8058 defines. The attempt ends and is reported as *sent*, not accepted |
| A `Location` naming `http` | **Refused.** Never downgraded |
| A `Location` naming any non-web scheme | **Refused** |
| More than **3** hops | **Refused.** A redirect loop is a fault, not a reason to keep asking |
| A 3xx with no `Location`, or one the policy does not model | **Refused** |

Nothing but the body is carried across a hop. There is no cookie to carry and no
`Authorization` header to forward.

---

## Retries

**None.** Ever, automatically.

`UnsubscribeRetryPolicy` is a type rather than an omission so that the zero in it is deliberate.
The Gmail adapter backs off and retries a 429 — copying that here would mean a second
unsubscribe request sent under permission you gave once, and the standard says nothing about
whether a given endpoint treats the request as idempotent.

One confirmation is one request. A failure is reported to you, and asking again is a new,
explicit action recorded as its own entry.

---

## What the app says afterwards

Never "you are unsubscribed". No status code can tell an app whether a mailing list removed
anybody; only the mail that arrives from now on can.

| Outcome | Wording |
| --- | --- |
| 2xx to a one-click request | **Unsubscribe request sent** — "accepted it… not confirmation that you have been removed from the list" |
| 3xx to a one-click request | **Unsubscribe request sent** — delivered; the answer doesn't establish what became of it |
| Error status, or no connection | **The unsubscribe request didn't go through** |
| Browser opened | **Unsubscribe page opened** — finishing it is yours |
| Mail app opened | **Unsubscribe message ready to send** — InboxSweep has not sent it and cannot |
| No mechanism, or refused metadata | **Unsubscribe not attempted** |

A test enumerates every one of these and fails if a headline claims completion.

---

## Activity

Unsubscribes appear in Activity beside archives, interleaved by time and rendered differently
because they say different things.

- **Only InboxSweep-initiated actions.** An unsubscribe you completed in a browser InboxSweep
  opened is recorded as *opening the page*, because that is what the app did. One you did in
  Gmail itself never appears at all.
- **No control on the row.** No undo, no retry, no re-send. An archive row offers an undo
  because there is one; an unsubscribe row says *why there isn't*, rather than silently
  offering nothing.
- **What is stored:** an identifier, the account, which mechanism, the destination **host**, an
  outcome, a timestamp, and the message the headers came from.
- **What is not:** the full URL, its path, its query — which is frequently a per-recipient
  token — any mail address, any subject, and the sender's name. The sender shown on a row is
  resolved from the mailbox cache through the message identifier, exactly as archive history
  resolves its messages, so it is never copied into a second file.

Bounded at 100 entries per account, on their own budget — a burst of archiving cannot evict the
record of an unsubscribe.

### History schema

The transaction file went from version 3 to version 4 by gaining **a new optional key beside the
existing one**. Nothing about an archive transaction changed and no entry is reinterpreted, so a
version-3 file still decodes with its archive history *and its live undo offer* intact. Versions
2, 3, and 4 are all readable; version 1 is still discarded, for the reasons
`MutationTransactionDTO` records.

Unsubscribe entries are a **second kind of entry**, not a reshaped first kind. An unsubscribe
names no messages, confirms nothing about a mailbox, and has no undo state — forcing it into a
transaction would have meant three fields that are meaningless or actively misleading.

---

## Gmail access

**No OAuth scope was added, and none was widened.** The app requests exactly what it requested
before this feature existed:

| Scope | For |
| --- | --- |
| `gmail.metadata` | Reading headers, labels, and dates |
| `gmail.modify` | Archiving |

`List-Unsubscribe-Post` was added to the list of metadata headers the app asks for — a
request-shape change that `gmail.metadata` already covered. A one-click unsubscribe touches
Gmail not at all: it is an HTTP request to the sender's own server, over a transport that has
never held a credential.

The app still never requests, and a test still fails if it ever does: send, compose, insert,
full access, settings, or contacts. It uses no Gmail settings or filter API.

---

## Interaction with proposals and protection

**A proposal cannot execute an unsubscribe.** "Likely newsletter" may surface that a mechanism
exists; you still open the review and confirm it. Heuristics may suggest attention. They may not
authorize action.

**Archive protection is not reused as an unsubscribe rule.** A sender whose mail looks
financial, transactional, or security-related is held back from *cleanup proposals* — and its
unsubscribe mechanism is still shown, because you are entitled to turn off your own bank's
marketing mail through the app that found it. What changes is the tone: the review says what was
noticed, says that unsubscribing affects future mail which may include receipts or notices that
travel on the same list, and states plainly that InboxSweep is showing you the mechanism rather
than recommending it. Nothing is blocked.

---

## Staleness and duplicates

A drifting archive confirmation would archive a different set of messages than the one on
screen. A drifting unsubscribe confirmation would send a request **to a different host** than
the one you read — which is the worst thing this feature could do. So a review is frozen when
you open it, and before anything is sent InboxSweep re-checks:

1. the account connected **now** is the one the review was frozen under — asked of the provider,
   not read from the snapshot;
2. the message the metadata came from is still loaded, still in scope, and still this sender's;
3. **the destination is still the same one** — re-derived from that message's current metadata
   and compared for identity, not merely "is there still a mechanism";
4. this confirmation has not already been acted on.

Any of those failing refuses the action and sends nothing anywhere. A sender that rotated its
endpoint between one page of mail and the next gets a refusal and an invitation to look again,
never a silent switch.

A single confirmation cannot become two requests: the identifier is spent for the life of the
session, and dismissing the sheet does not return it. Deliberately unsubscribing again means
opening the review again, which freezes a new identifier — because that is a new decision.

---

## Limitations

- **Header-only.** An unsubscribe link in the body of an email is invisible to InboxSweep, and
  always will be while it never reads bodies. The options screen says so rather than implying it
  has found everything.
- **A mechanism is not a promise.** That a sender published an unsubscribe endpoint does not
  mean they honour it. InboxSweep cannot tell you whether they did; only later mail can.
- **The loaded window.** Detection describes the messages that have been fetched. Loading more
  of a mailbox can change what a sender's opportunity looks like.
- **One sender at a time.** There is no bulk unsubscribe, by design, and no shape in the code
  that could express one.
- **No verification of the destination.** InboxSweep shows you the exact host the sender named.
  It does not vouch for it, check it against a list, or judge whether it is reputable.

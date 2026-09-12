# Working on InboxSweep

## The synthetic mailbox

`SampleMailProvider` is a Debug-only provider that vends an invented mailbox. It is not a demo
mode bolted on the side: it is a `MailProvider` like any other, reached through the same
protocols, and it is what the entire UI test suite runs against.

By default it has **no mutation boundary at all**. That is the point. A provider vends an
archiver only if it can write, so a sample session has no code path to a mutation rather than a
guard someone has to remember, and the Archive control is *absent* rather than disabled.

Launch arguments turn individual capabilities on, so each one can be exercised in isolation:

| Argument | What it does |
| --- | --- |
| `--sample-data` | Starts on the synthetic mailbox |
| `--ignore-stored-credentials` | Empty, process-lifetime credential store, so the signed-out screen appears whether or not this Mac has a saved sign-in |
| `--sample-archiving` | Gives the synthetic mailbox an in-memory archive boundary. No transport, so nothing can reach Gmail |
| `--sample-unsubscribe` | Gives it a one-click unsubscribe boundary and an opener that opens nothing |
| `--sample-activity` | Seeds invented transactions, so the populated Activity screen can be exercised |
| `--sample-rules` | Seeds one enabled sender rule. An authorization, not a capability: inert without `--sample-archiving` |
| `--ui-test-window` | The deterministic window harness described below |

Each is a `#if DEBUG` constant in the app, matched by a string in `UITestLaunchArgument` in the
UI test target, which cannot import the app's own types because it drives it from outside its
process.

## The deterministic window harness

`UITestWindow` exists because a UI test run on a developer's Mac is not testing the app, it is
testing the desktop. Two windows from other applications covering a 1,680-point display make
**every control in InboxSweep unhittable**, and the runner's error then names InboxSweep's
scroll view rather than the windows that are actually in the way.

It is `#if DEBUG`, gated behind `--ui-test-window`, and touches nothing but window geometry,
activation, and full-screen state. No provider, no credential store, no view state. A Release
build does not contain it, and a Debug build launched without the argument does not run it.

What it does:

- a **fixed content size, centred**, so the geometry under test is not a measurement of where the
  developer last dragged the window;
- **frontmost, above other applications**;
- **full screen**, which is the one that actually works: a full-screen macOS window gets a Space
  of its own, where there is no other application's window to be behind.

It re-asserts the request until the window *reports* it is full screen rather than until a timer
expires, treats the system's notifications as the signal that the transition finished, and holds
the state for the life of the process rather than applying it once at launch. It publishes its
phase as a hidden accessibility element, so a failing case can say *the window never became
deterministic* instead of blaming whichever control the test reached for next.

!!! note "It papers over nothing"

    A control that is genuinely unreachable, behind a sheet or below a scroll view's fold, still
    is, and the case still fails. All it removes from the test is the rest of the desktop.

[Testing](testing.md#what-a-clean-runner-measured) records what a hosted runner measured about
whether any of this is needed there.

## Conventions

- **Dependencies point in one direction.** Domain code imports no Gmail types. If you find
  yourself adding an import to reach a provider detail, the seam is in the wrong place. See
  [Architecture](architecture.md).
- **Facts and verdicts are separate types.** A judgement never lands on `SenderSummary`.
- **New capabilities are new optional protocols**, not new methods on an existing one. That is
  what keeps "can this thing change a mailbox?" answerable without reading an implementation.
- **Nothing is claimed before the provider confirms it.** Reconcile from the reply, never from
  the request.
- **Bound everything.** Every load depth, every retention count, every rule pass. An unbounded
  loop over someone's mailbox is a denial of service aimed at their own quota.
- **State limits where a user can see them.** A limit that exists only in the code is a claim
  nobody can check.

## Repository hygiene

Two scripts run locally and in CI:

```bash
Scripts/check_no_em_dashes.sh
Scripts/check_privacy.sh
```

The first enforces a house punctuation rule: **no Unicode em dash in tracked text**, ever. It is
machine-enforced precisely because an em dash is invisible in review and arrives one paste at a
time. The fix for a failure is to rewrite the sentence, not to substitute a hyphen.

The second fails on an address outside the reserved documentation domains, on credential-shaped
content of plausible length, on files that belong only on one developer's Mac, and on absolute
paths into a home directory. It cannot prove the absence of real data, and says so in its own
comments.

## Documentation

This site is [MkDocs](https://www.mkdocs.org/) with
[Material](https://squidfunk.github.io/mkdocs-material/), built with `--strict` so a broken
internal link, a missing image, or a page missing from the navigation fails the build.

```bash
pip install -r requirements-docs.txt
mkdocs serve          # live preview at http://127.0.0.1:8000
mkdocs build --strict # what CI runs
```

Dependencies are pinned exactly in `requirements-docs.txt`. `--strict` guards the content; only a
pin guards the generator.

The README is deliberately short and points here. Detail belongs on these pages, in one place,
rather than in two places that drift apart.

### Writing here

- **Be exact and conservative.** Archiving is not deleting. An unsubscribe request is not a
  completed unsubscription. A rule runs only while the app is loading mail. Proposals recommend;
  users authorize.
- **State the limits where the claim is made**, not only on the [Limitations](limitations.md)
  page.
- **Never overstate** security, privacy, reliability, or background behaviour. If a measurement
  supports a claim, give the measurement. If it does not, say what is unknown.

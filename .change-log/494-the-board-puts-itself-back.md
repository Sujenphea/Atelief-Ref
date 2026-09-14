# 494 — the board puts itself back

## Summary

493 found that a rednote board sweep captured **78 of 116 notes and reported `complete`**,
because the board feed pages **forward only** and the run never held page A. Its answer was
to **refuse**: a sweep that cannot prove it holds the opening slice halts resumable and tells
the user to reload the board page and start again.

That is a guard, not a fix — the user still has to do the reloading. This is the fix. Before
the sweep enumerates anything, if it is not already at the feed's start it **puts the feed
back itself, in page**, and 493's rule becomes the **assertion that the reset worked**.
Nothing about 493 is weakened, bypassed or duplicated: `isFirstBoardFeedRequest` is the same
predicate, `RednoteFeedStartError` is the same halt, and a reset that did not work falls into
it rather than around it.

> **Index.** This entry is 494. 488–493 are taken; indices are never reused.

## The mechanism, verified live

A **reload is not available** — it tears down the content script the sweep runs in, which is
why 493 rejected it. But the SPA can be **driven**, which is the same idiom
`createPageNoteDriver` already relies on for note-opening.

Verified in the user's own browser on 2026-09-14, on a **mid-scrolled board**, with the hook
logging every board-feed request url:

```
[req] cursor= "6a804923000000002c001f0c"   <- from scrolling
[req] cursor= ""                            <- after navigating back to the board
```

The second line is the opening slice, refetched: `cursor=` empty is exactly what
`isFirstBoardFeedRequest` reads. What produced it was a **pair** of moves —

1. **forward-navigate to another SPA route**: click the `/user/profile/<id>` link the board
   itself renders, and
2. **browser-BACK to the board**.

The back is what triggered the refetch. The two legs are not interchangeable with anything
simpler. A lone `history.back()` from a state nobody verified pops whatever entry happens to
sit under the board and lands the sweep somewhere else; assigning `location` kills the sweep
outright. 492 already found that rednote sometimes overlays and sometimes routes, so "click
something and go back" is not a family of equivalent gestures — it is this one.

**This was one board, in one SPA build.** Which is precisely why 493's guard stays: the reset
is an attempt, the refetch is the evidence, and a build that restores the board from its
store instead of refetching gets 493's refusal exactly as it does today.

## Where it lives

**`createPageFeedResetter` — `rednote-detail-client.js`.** The browser glue: find the
board's own profile anchor, click it, settle, `history.back()`, settle, scroll to the top.
It never waits for a response and never judges one — the evidence is a **request url**, and
the only thing that sees those is `rednote-source.js`. It returns `true` only when the board
was actually left and actually returned to.

It lives in the note-expansion file, which is not where a feed reset obviously belongs,
because of what it is made of. `createPageNoteDriver` already knew how to click an anchor the
page rendered, let the SPA settle, pop a history entry and put the scroll back. Those four
moves are now module-level functions — `hrefOf`, `clickAnchor`, `goBack`, `scrollWindowTo`
(plus `pathnameOf`) — **shared by both drivers** rather than copied into a second file. The
copy is the defect: two versions of "how you drive this SPA" drift, and the one that drifts
is the one that quietly stops working on a live page. `createPageNoteDriver`'s own behaviour
is unchanged; its private `hrefOf` and its two inline `try`/`catch` navigation blocks are now
the shared ones.

**The orchestration — `rednote-source.js`.** Wrapped around 493's wrappers, in the same file
and for the same reason: `intercept-source.js` is shared with X and **is untouched**.

Three decisions carry it.

**It is awaited on the real signal, not on a sleep.** The hook already forwards every
board-feed response with its request url; the wait polls until one arrives that satisfies
`isFirstBoardFeedRequest` — 493's predicate, reused, not re-written — bounded by
`FEED_RESET_TIMEOUT_MS` and then given up cleanly. And it is **scoped** exactly as 493's
evidence is: another board's page A, whenever it arrives, licenses nothing.

**It is skipped when it is not needed.** The common case — a board the user just opened — has
the opening slice in the hook's replay and drives **nothing**. That is not an optimisation.
An unnecessary route change is real automation footprint against a site running an active
risk-control layer (`xhsFingerprintV3`, `as.rednote.com/api/sec/v1/shield/webprofile`) which
has already answered a scripted request with **HTTP 461**. The cost of the skip is 493's own
timing argument moved earlier: the controller posts the replay request and returns, the
buffered responses land asynchronously, so the decision waits `FEED_RESET_GRACE_MS` for them
— and ends the moment the opening slice arrives, so a fresh board pays one poll.

**What the previous page session fetched is dropped.** A response that arrives before the
decision is **held**, not forwarded, and a successful reset discards everything held before
its refetch. This is not fastidiousness. A board scrolled to its very *bottom* replays the
exhausted **tail** page (`has_more:false`): queue that ahead of the refetched page A and
enumeration *ends* before page A is ever yielded — a `complete` sweep missing the opening
slice, which is 493's defect rebuilt out of its own repair. A reset restarts the feed, the
board re-serves every page from the top, so nothing is lost and no extra fetch is spent.

## What a failed reset does

It falls into the guard, never around it. Every one of these ends in
`RednoteFeedStartError`, a **resumable** halt with nothing relayed and the checkpoint kept,
and the popup still says *reload the board page, then start the sweep again*:

| case | what happens |
| --- | --- |
| no `/user/profile/…` anchor (an empty board, a changed layout) | no away leg, so no pair, so no reset is driven at all |
| the click does not route (an overlay, an intercepted anchor) | **the history is left alone** — the board is still on top of it, and a back would pop the *board* off |
| the back lands somewhere that is not the board | reported and **not retried**: a second blind back is the same unknown state one step further away |
| the page driver throws | a driver that threw is a driver that did not reset |
| the SPA restores from its store instead of refetching | the refetch never arrives, the wait is spent, the guard fires |

The one thing a failed reset must never be is a sweep that carries on from the middle. It
isn't: the refusal is reached the moment the attempt is known to have failed.

## Two edge cases worth naming

**Scroll position.** A back navigation restores the offset the board had when it was left —
halfway down the grid, which is exactly where the SPA's infinite scroll would fetch the
*next* page from, defeating the refetch the reset exists to cause. So
`history.scrollRestoration` is pinned `manual` across the navigation, **and released
afterwards** (it is a property of the user's page, not ours to keep), and the viewport is put
at 0 after the back.

**Firing twice** — a resumed sweep, a retried start, two enumerations of one source. The
attempt is memoised, so a concurrent second pull *awaits the first* rather than racing a
second navigation onto the page, and a later pull drives nothing because the feed is already
at its start.

## The wasted-work window, closed

493's report left one open: with note-opening on, its refusal fires only after the first
queued page has been **expanded** — up to a page of paced SPA note-opens spent on a sweep
that was always going to halt.

It is now **closed entirely**, in two parts. The reset runs before anything is pulled from
the seam, so no expansion can precede it. And because the refusal is reached the moment the
reset is known to have failed — the grace and the timeout are both already spent, so there is
nothing left to wait for — a refused sweep never pulls a page at all, and opens **no** notes.
That is asserted: `a refused sweep opens NO notes at all`.

## Files changed

`extension/src/rednote-detail-client.js` (`createPageFeedResetter`; `hrefOf`, `clickAnchor`,
`goBack`, `scrollWindowTo`, `pathnameOf` hoisted to module scope and shared with
`createPageNoteDriver`), `extension/src/rednote-source.js` (the hold/flush, the grace, the
reset and its bounded wait, and 493's refusal reached from one place),
`extension/src/config.js` (`FEED_RESET_GRACE_MS`, `FEED_RESET_TIMEOUT_MS`,
`FEED_RESET_POLL_MS`, `FEED_RESET_SETTLE_MS`), `extension/src/bulk-controller.js` (wiring the
live resetter).

`extension/src/intercept-source.js` is **untouched** — the seam is shared with X and the rule
is rednote's alone. The expansion path is untouched: **2C** (counting `no_note_card`
separately and reporting "expanded N of M", since the grid is virtualised and only ~13 cards
mount) and **3B** (per-page expansion batching, deferred deliberately) remain open elsewhere.

Unlike `noteOpen`, the reset's budgets are **not** threaded through `PLATFORM_PACING`. Those
exist because expansion's cost varies by platform; these describe one SPA's one forward-only
feed, there is no second platform to vary them for, and the source already reads them from
`config.js`. A second access path would add nothing but somewhere for a typo to fall back to
the default and look like it worked.

Tests: `rednote-detail-client` (+7, the driver against a fake page that can actually
navigate), `bulk-rednote-integration` (+12, the reset through the real parser, real seam and
real engine).

## Verification

`npm test` 928 → **947 total, 944 pass, 0 fail, 3 skipped** (the 096 corpus and page-signal
fixtures, still not rednote's). `node scripts/drift-check.js` prints `No drift`, all nine arms
pass, and it still exits **2** on the X/Instagram/Pinterest fixture-staleness arm, which
pre-dates this change.

Sixteen deliberate breakages, each failing the tests that name it and no others:

| mutation | fails |
| --- | --- |
| the reset never runs (493's guard alone, restored) | 8 |
| the skip is gone — every board is navigated | 2 — the fresh board and the one-page board |
| the previous page session's responses are kept | 2 — including the stale-tail sweep |
| the refusal is not reached until the first yield | 1 — the refused sweep that opens notes |
| the evidence is no longer scoped to this board | 2 — 493's cross-board test and this one's |
| the attempt is not memoised | 1 — two concurrent pulls drive the page twice |
| 493's refusal deleted outright | 10 — every refusal in the suite, 493's five included |
| the reset does not wait for the refetch at all | 1 — the late-refetch test |
| the click is no longer checked for having routed | 1 |
| where the back LANDED is no longer checked | 1 |
| the browser is left free to restore the old scroll offset | 1 |
| the page's own `scrollRestoration` is never put back | 1 |
| the viewport is not put at the top after the reset | 1 |
| the away leg is ANY anchor (selector widened **and** shape check dropped) | 4 |
| the profile href shape is not checked | 2 — the decoy `/login?redirect=/user/profile/<id>` |
| the BACK leg is dropped — the click alone is the reset | 3 |

Two notes on honesty rather than on results. Widening the selector **alone**
(`a[href*="/"]`) changes nothing and fails nothing: the href shape check subsumes it, so that
mutant is equivalent, and the pair is mutated together above. And the memoisation survived its
first mutation because a *sequential* second pull is already stopped by the opening slice
having arrived — the test was rewritten to pull **concurrently**, mid-navigation, which is
the only shape that tests it. Both were found by mutating, not by reading.

No mutant survived. Every mutation was reverted before committing.

## Migration notes

- **A rednote sweep of an already-scrolled board now fixes itself** instead of refusing. It
  navigates to the board owner's profile and straight back — the user will see this happen —
  and then sweeps the whole feed from page A. A sweep started on a freshly-loaded board is
  unaffected and navigates nothing.
- **493's refusal still exists and still reads the same.** It is now what fires when the
  reset did not work, rather than what fires whenever the board was scrolled.
- `createRednoteSource` takes four new optional arguments (`resetFeed`, `graceMs`,
  `resetTimeoutMs`, `resetPollMs`) and a `log`. **Omit `resetFeed` and the source behaves
  exactly as 493 left it** — which is what every test predating this change relies on.
- `createPageNoteDriver`'s behaviour is unchanged; it is now built from shared moves.
- Nothing in the sweep's UI, spec, messages or storage changed.

## Still unverified without another live run

- **Whether the reset works on that board, end to end, inside a sweep.** The `cursor= ""`
  refetch was reproduced by hand in the console; what has not been watched is the sweep
  driving it and then capturing all **116**. That number is the check.
- **Whether one board, one build, generalises.** Everything above rests on a single
  observation. A build that restores from its store, a board whose profile link is rendered
  differently, or an SPA that pushes two history entries for one route change all end in
  493's refusal — which is safe, and is also how we would find out.
- **What the settle needs to be on a real page.** `FEED_RESET_SETTLE_MS` is 1200 ms, three
  times the note-open settle, reasoned from a route change being a whole view swap rather
  than an overlay. It has not been measured. Too short shows up as "the profile link did not
  route away from…" in the log and degrades to the guard, never as a wrong capture.
- **How long the grace costs in practice.** `FEED_RESET_GRACE_MS` is 1500 ms, and a fresh
  board should pay only until its replay lands (one poll, 250 ms). Unmeasured on a live page.

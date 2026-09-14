# 493 — the page that scrolling cannot reach

## Summary

A live bug, found the way 492 was: by running the real thing against a real board and
counting. A rednote board sweep captured **78 notes and reported `complete`**. The board
holds **116**. Nothing failed, nothing warned, and the ledger recorded a whole board.

The board's own responses, read off two passes on 2026-09-14, say where the other 38 went:

| page | notes | next cursor |
| --- | --- | --- |
| A | 38 | `6a804923…` |
| B | 37 | `6a650248…` |
| C | 38 | `6a616185…` |
| D | 3 | `""` (end) |

The sweep saw **B · C · D = 78**. 116 − 78 = 38 = page A, exactly.

**Why it is unreachable, not merely missed.** The board feed is cursor-**forward**: a
response's `cursor` buys the *next* slice and no request walks back. The driver's only lever
is `win.scrollTo(0, body.scrollHeight)`. So if the board was already scrolled when the sweep
started, page A was fetched in an *earlier page session*, is long out of the hook's replay
buffer, and there is no sequence of scrolls that can ask for it again. The sweep then swept
everything it could reach and called that the board.

This is the T0/T6a class — a wrong answer that reports success — and the decision (**1A**)
is to refuse: a sweep that cannot prove it holds the beginning of the feed **halts
resumable** and tells the user to reload the board and sweep again.

> **Index.** This entry is 493. A concurrent, unrelated session holds 488–492; indices are
> never reused.

## What was rejected

- **Enlarging the replay buffer.** The buffer is not the constraint.
  `RESPONSE_HOOK_REPLAY_LIMIT` is 25 responses under an 8 MB cap, and a four-page board
  needs four. Page A was never in *this page session* at all — it was fetched before the
  tab's last navigation, or before the user scrolled past it in a session the buffer has
  since rolled over. A bigger buffer buys nothing and hides the question.
- **Reloading the tab for the user.** A reload tears down the content script the sweep runs
  in — it would kill the thing doing the asking.
- **Documenting it.** "Scroll to the top first" in a README is not a guard; the failure is
  silent precisely because nobody can see it happening.

## Where the check lives, and why there

Three small pieces, no change to the shared seam:

**1. `isFirstBoardFeedRequest(url)` — `bulk-rednote.js`.** The evidence is in the request
URL and nowhere else: the board's opening request carries an **empty cursor**
(`…&board_id=<24-hex>&num=30&cursor=&image_formats=…`), every later one carries the previous
response's cursor. It reuses `cursorFromRequestURL` rather than parsing a second time —
and adds one clause that is the whole of its honesty. `cursorFromRequestURL` answers `null`
for an empty cursor **and** for a url it could not parse; those must not be the same answer
here, or an unreadable url would present itself as the first page and wave the sweep
through. Requiring a readable `board_id` is what separates them: a query that parsed has
one, a string that did not, has nothing.

**2. Two wrappers in `rednote-source.js`, and nothing in `intercept-source.js`.** The seam
is shared with X and the rule is rednote's alone. `parsePage(json, { host })` never sees the
request url, so the *observation* has to happen where the url still exists — `onResponse`,
which the source now wraps — and the *judgement* has to happen on the pull side, where a
throw becomes a resumable halt. The observation is scoped exactly as ingestion is: another
board's opening page is evidence about a feed we are not sweeping, and a stale replay-buffer
entry from it must not license this sweep.

**3. `RednoteFeedStartError`, thrown from `enumerate`.** The engine already treats an
enumeration throw as a **resumable** halt — checkpoint kept, job closed `paused` — which is
what `RednoteStallError` and the 461 `RednoteChallengeError` rely on. The refusal joins them
rather than inventing a fourth kind of stop.

## The timing, which is the whole of the correctness

The controller posts the replay request and **returns immediately**; the hook's buffered
responses come back asynchronously, one `postMessage` task each, and land during the
source's first settle. A check at construction — or on the first response *parsed* — would
refuse a perfectly good sweep for the crime of not having received its replay yet.

So the rule fires at the first moment there is anything to judge: **the first item about to
be yielded**. By then the queue has been filled by the whole replay burst, and the question
"did the opening slice arrive?" has an answer. It asks whether page A *arrived*, never
whether it arrived *first* — so a burst delivered out of order, or a page A behind a later
page, still counts.

There is a second firing point, and it is not decoration: a feed that yields **nothing**
never reaches a first yield. A board scrolled to its very bottom before the sweep starts
has one thing in the buffer — the exhausted tail, `has_more:false, notes: [], cursor: ""`,
fetched with a cursor — which parses cleanly, ends the feed and yields nothing at all.
Without the same rule applied where enumeration *ends*, that closes `complete` having
captured none of a 116-note board: the quietest possible version of this bug.

## The edge cases, each pinned

| case | behaviour | why |
| --- | --- | --- |
| board small enough that page A is also the last (`has_more:false`) | **sweeps** | the rule asks only for the beginning; a one-page feed is all of it |
| replay arrives a tick late (nothing at the first pull) | **sweeps** | judged at the first yield, after the settle — the false-refusal this was designed against |
| page A delivered *after* a later page | **sweeps** | arrival, not order |
| the same page replayed twice (observed live: two responses on cursor `6a616185…`) | **refused** | repetition is not evidence; a rule that counted responses would pass this |
| a request url that cannot be parsed | **refused** | an unreadable url proves nothing, and null-cursor alone would read it as page A |
| another board's page A in the buffer | **refused** | scoped like ingestion — it is the wrong feed's beginning |
| a **resumed** sweep starting mid-feed | **refused** | see below |
| a 461 refusal, or a stall | unchanged, both win | they are checked earlier in the seam and have better-fitting messages; all three are resumable |

**The resume case, decided deliberately.** The rule fires on a resume too. `resumable:
"scroll"` means the engine persists no cursor and a resume **re-walks** from wherever the
page now is — and the source cannot even tell that it is a resume, since `enumerate` ignores
the cursor argument it is handed. Exempting resumes would be wrong on the merits anyway: a
resume that starts at page B reaches exactly the notes a fresh one would, dedup-skips what
it already has, and then closes `complete` and **clears the checkpoint** with page A still
never seen. Being a second attempt does not put the top of the feed back within reach.

## How the refusal reaches the user

`REASON_MESSAGE` cannot serve this one. That table answers `resolveSweepSpec`, which refuses
**before** a sweep starts and knows only the tab's URL; "this board was already scrolled
past its first page" is something only the running sweep can discover. `sweepWarning` is the
pre-start account-risk gate. The mechanism that renders a **runtime** halt is
`terminalMessage`, and it was throwing the reason away: every resumable halt read
`Paused (resumable) — N ingested.` whether the sweep hit a wall, was refused by rednote, or
started in the middle of a board.

It now appends the reason, via a new `haltReason(result)`. The engine stringifies the error
(`String(error)` → `"RednoteFeedStartError: The sweep did not…"`), so the class name is
trimmed off the front — a fact about our source tree, not copy for a user — and anything
without that prefix passes through whole. The **message lives on the error class**, not in a
popup string table: there is exactly one of it, and a second copy could only ever disagree.

> The sweep did not start at the top of this board. rednote's board feed only pages FORWARD,
> so notes above where the page was already scrolled cannot be fetched at all — sweeping from
> here would silently miss them. Reload the board page, then start the sweep again without
> scrolling first.

The stall and the 461 refusal now reach the popup the same way, which they never did before.

## Files changed

`extension/src/bulk-rednote.js` (`isFirstBoardFeedRequest`),
`extension/src/rednote-source.js` (`RednoteFeedStartError`; the `onResponse` and `enumerate`
wrappers; `resumable` passed through from the seam rather than restated),
`extension/src/popup-view.js` (`haltReason`, and `terminalMessage` rendering it).

`extension/src/intercept-source.js` is **untouched** — see above.

Tests: `bulk-rednote` (+2, the predicate), `bulk-rednote-integration` (+8, the rule through
the real parser, real seam and real engine), `popup-view` (+3, the copy reaching a human,
built from the real error object rather than pasted text).

## Verification

`npm test` 915 → **928 total, 925 pass, 0 fail, 3 skipped** (the 096 corpus and page-signal
fixtures, still not rednote's). `node scripts/drift-check.js` prints `No drift`, all nine
arms pass, and it still exits **2** on the X/Instagram/Pinterest fixture-staleness arm,
which pre-dates this change.

Ten deliberate breakages, each failing the tests that name it and no others:

| mutation | fails |
| --- | --- |
| the rule never refuses (the shipped bug, restored) | 5 — every refusal test |
| `isFirstBoardFeedRequest` drops the `board_id` parseability clause | 1 — the unreadable-url test, alone |
| it drops the board-feed path clause | 1 — the same test, on the telemetry/detail urls |
| its cursor test inverted (`!== null`) | 27 — every rednote sweep in the suite |
| no trailing judge (a feed that yields nothing is never judged) | 1 — the empty-tail board |
| judged at construction instead of at the first yield | 1 — the late-replay test, which is what it is for |
| the scope gate dropped from the evidence | 1 — another board's page A licensing this sweep |
| only the FIRST response observed (order-sensitive) | 3 — the out-of-order test, and both pre-existing cross-board scope tests |
| `terminalMessage` drops the halt reason | 1 |
| `haltReason` keeps the class-name prefix | 2 |

No mutant survived. Every mutation was reverted before committing.

## Migration notes

- **A rednote sweep of an already-scrolled board now refuses instead of under-capturing.**
  The halt is resumable: nothing is relayed, no checkpoint is cleared, and the popup says to
  reload the board and sweep again without scrolling. A sweep started on a freshly-loaded
  board is unaffected — that is the path every existing test already took.
- **Every resumable halt now says why** in the popup's terminal line. A stall reads
  `Paused (resumable) — 78 ingested. rednote board stalled: no new page after 4 scroll
  attempt(s).` where it used to read only the count. Nothing about an app Pause or a Cancel
  changed.
- `createRednoteSource` still returns `{ enumerate, onResponse, resumable }` and still
  declares `resumable: "scroll"`; the returned object is now rednote's wrapper around the
  intercept source rather than the source itself.
- The note-open/expansion path is untouched. **2C** (counting `no_note_card` separately and
  reporting "expanded N of M", because the grid is virtualised and only ~13 cards are
  mounted) and **3B** (per-page expansion batching, deferred on purpose) remain open and
  belong to other commits.

## Still unverified without another live run

- **Whether a refused sweep, reloaded and re-run, captures all 116.** The measurement that
  found this bug was a sweep; the fix's happy path has been reproduced only in tests. The
  next live run on that board is the check, and its number is 116.
- **Whether the board ever issues its opening request with the `cursor` parameter absent
  rather than empty.** Both read as the first page here, deliberately; only the empty form
  has been observed.
- **How large the expansion cost of a refusal is.** With note-opening on, the refusal fires
  after the first queued page has been expanded but before any item is relayed — so a
  refused expansion sweep can spend one page's worth of note-opens before halting. Cheaper
  than the sweep it prevents, and not yet watched on a real board.

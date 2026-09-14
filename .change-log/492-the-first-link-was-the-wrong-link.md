# 492 — the first link was the wrong link

## Summary

A live bug, found by running the real thing. Not by a test — 906 of them passed while every
note-open on a real board opened a **404 page**, and the only thing that noticed was a user
watching the browser.

`createPageNoteDriver` opens a note by clicking its card's own link, and it found that link
with `doc.querySelector('a[href*="<note_id>"]')`. A live board
(`https://www.rednote.com/board/69322476000000001202811f`) was probed in the console on
2026-09-14, dumping every `href` that carries a 24-hex id **in document order**:

```
/user/profile/65d3e54f000000000503359d
/user/profile/65d3e54f000000000503359d?tab=fav&subTab=board
/board/69322476000000001202811f/6a9f696e000000000d020daa                        <- NO token
/board/69322476000000001202811f/6a9f696e000000000d020daa?xsec_token=AB40…Y1w=&xsec_source=
```

The board renders **two anchors per note and the tokenless one is first**. `querySelector`
returns the first match, rednote answers 404 for a note URL with no `xsec_token`, and the
SPA therefore never issued the `POST /api/sns/web/v1/feed` the expander was waiting for. So
`findLink` now chooses on the **token**, and document order is only the tie-break among the
anchors that carry one.

> **Index.** This entry is 492. A concurrent, unrelated session holds 488–491; indices are
> never reused.

## The tokenised anchor, not a constructed URL

The brief's alternative was to build the URL from `boardId` + `noteId` + the item's own
`xsecToken` — which the cover pass already has as a LOCAL `BulkItem` field, precisely
because the feed row ships it — and so stop trusting what the page happens to render. That
was weighed and **rejected**, for one reason that is load-bearing and one that is new:

- **A constructed URL still has to be OPENED.** The whole driver exists because assigning
  `location` tears down the content script, the engine and the sweep with it; a click on the
  SPA's own anchor is what keeps the grid — and the intercept source's scroll position —
  alive underneath the overlay. Synthesising an anchor and clicking it only works if
  rednote's router adopts a node it never rendered (delegated click handling); if it binds
  its handler per component instead, the click is a **real navigation** and the sweep dies
  mid-board. Rewriting the rendered anchor's `href` before clicking has the same fork with
  the same downside. Neither can be told apart without another live run, and the failure
  mode of guessing wrong is the worst one this file has.
- **The page already has the token, in the shape the router expects.** The tokenised anchor
  is the SPA's own, byte-for-byte, including whatever route it decided to render. Building
  a URL would mean also choosing a *route*, and there are now three of them.

Which is the second new fact. A note is reachable at `/explore/<id>`, at
`/discovery/item/<id>` (the user supplied a live one, carrying `xsec_source=pc_user`) and at
`/board/<board_id>/<note_id>` (what a board card renders). Had the driver constructed a URL
it would have had to pick one, and the board card's shape is not the one a hand-opened note
produces. Matching the **id anywhere in the href** is what makes all three work, so that is
kept exactly as it was; the defect was never the match, only which of the matches won.

`xsec_source` is deliberately not part of any test here. It is empty on the board card and
`pc_user` on the user's own URL — it varies by where the reader came from. Only
`xsec_token` decides whether a URL opens.

## What `findLink` does now

1. The id guard (`/^[A-Za-z0-9_-]{4,64}$/`) first, unchanged and still the only thing ever
   interpolated into a selector.
2. `querySelectorAll('a[href*="<id>"]')` — every anchor for the note, in document order.
3. The **first one whose href carries a non-empty `xsec_token`** wins.
4. Failing that, the first anchor wins anyway, and the fallback is **logged**. Refusing
   would report `no_note_card` for a card that is plainly on the page and would lose every
   note the day rednote stops rendering the tokenised anchor; a 404 that degrades loudly is
   the better failure. `xsec_token=` with nothing after it counts as tokenless, because it
   is.

**The token is never interpolated into anything.** It contains `=` and `-`, it is
page-supplied, and it could contain a quote — so the preference is expressed as a JS filter
over the matched nodes rather than as a second attribute term in the selector, where a
breakout would be possible. A test asserts the document is asked for exactly one selector
and that it contains neither the token nor any token material.

## One notion of "a note URL", shared

`closeNote`'s history fallback asked `/\/explore\//` of the pathname — a private copy of a
route shape, written when only one was known. On the live board, where the SPA routes to
`/board/<board_id>/<note_id>`, **that fallback could never fire**. And the extractor
(`extractors/rednote.js`) held a second private copy that knew two shapes.

So there is now one definition, `rednoteNoteId(urlOrPathname)`, exported from the extractor
and used by both. It accepts a full URL or a bare `location.pathname`, and it knows all
three routes. The board route is the only one whose id is shape-tested
(`/^[0-9a-f]{16,32}$/i`, the bound `bulk-context.js` already uses for a board id): nothing
but a note lives under `/explore/`, while `/board/<id>/…` shares its namespace with the
board page itself, so `/board/<id>/edit` must not read as a note. Two segments is still the
board and still not a note, which the extractor has always relied on.

Everything else in `closeNote` is untouched — Escape first, then the history fallback, then
the `scrollY` restore, all in the `finally` that gives the board back even when a challenge
throws.

The extractor gains the board route for free, and it needed it: a single capture
right-clicked on a board card previously fell through to `liveURL` and recorded **no
`noteId`**, while a sweep of the same board recorded one for every note.

## A 404'd open is not a successful one — checked, not fixed

The brief asked whether a note that opens to a 404 can be told apart from a note whose card
was never found. It can, and the distinction is already right, so nothing was changed:

| what happened | `openNote` | `reasons` | `closeNote` | counted |
| --- | --- | --- | --- | --- |
| no card on the page | `false` | `no_note_card` | not called | `degraded`, sweep `partial` |
| opened, nothing answered (the 404) | `true` | `timeout` | called | `degraded`, sweep `partial` |

Neither is ever counted as `expanded`, both make the sweep partial, and the two already have
separate reason keys and separate existing tests. What is **not** distinguishable is a 404'd
open from a healthy open whose detail response never arrived — both are `timeout` — and
separating those would need a live-verified DOM signal for rednote's 404 page, which no
capture holds. The new log line on a tokenless fallback is the closest warning available
without one.

## Files changed

`extension/src/rednote-detail-client.js` (the token-first `findLink`, `hrefOf`, the shared
routed-note test in `closeNote`, and the driver's doc comment, which no longer calls the
card's link shape unverified — it was probed),
`extension/src/extractors/rednote.js` (`rednoteNoteId`, all three routes, and `extract`
rewired onto it).

Tests: `rednote-detail-client` (+7), `extractors` (+2). `fakeWindow` in
`rednote-detail-client.test.js` was rewritten — see below; it is the reason this entry has a
mutation that survived.

## Verification

`npm test` 906 → **915 total, 912 pass, 0 fail, 3 skipped** (the 096 corpus and page-signal
fixtures, still not rednote's). `node scripts/drift-check.js` prints `No drift`, all nine
arms pass, and it still exits **2** on the X/Instagram/Pinterest fixture-staleness arm,
which pre-dates this change.

The live anchors are pinned as a fixture **in the order the page emits them**, tokenless
first, because the ordering *is* the bug.

Thirteen deliberate breakages, each failing the tests that name it and no others:

| mutation | fails |
| --- | --- |
| `findLink` reverted to bare document order (the shipped bug) | 4 |
| `TOKENISED` accepts an EMPTY `xsec_token=` | 1 — the empty-token test, alone |
| `TOKENISED` matches any href (a tokenless anchor passes as tokenised) | 5 |
| the note-id guard dropped | 1 — the injection test |
| the tokenless fallback removed (a tokenless-only card refuses) | 3 |
| the tokenless open stops logging | 1 |
| `findLink` asks a second selector built from the token | 1 — the interpolation test |
| `closeNote` back to its private `/explore/` route test | 1 |
| `rednoteNoteId` forgets `/board/<board>/<note>` | 2 |
| `rednoteNoteId` drops the board tail shape guard | 2 |
| `rednoteNoteId` forgets `/discovery/item/<id>` | 2 |
| `rednoteNoteId` forgets `/explore/<id>` | 4 |
| `hrefOf` ignores `getAttribute` and reads only `node.href` | 4 |

**One mutant survived, and closing it was the useful part.** Deleting the note-id guard
outright failed **nothing** — the pre-existing injection test was checking nothing at all,
because the fake document's selector parser was a single regex that returned `[]` for
anything it did not recognise. A guard breakout produces a *valid* selector, not a malformed
one, so the fake made the attack unreachable and the test passed either way.

`fakeWindow` now models the three behaviours that decide whether a breakout bites: a comma
makes a selector LIST whose terms are unioned in document order, `[href*=""]` matches
nothing (per CSS), and an unparseable selector **throws** the way `querySelectorAll` throws
`SyntaxError`. The injection test then aims at the real harm — an id of
`x"], a[href*="/user/profile` steers the click at a profile anchor, and clicking one is a
full navigation off the board, the single thing this driver exists to avoid — and it fails
the moment the guard goes.

Every mutation was reverted before committing; `git diff` over `src/` is the change above
and nothing else.

## Migration notes

- **A rednote expansion sweep against a live board should now actually expand.** Before this
  it opened a 404 for every note and degraded each one into `reasons.timeout`; the cover
  pass was unaffected then and is unaffected now.
- `rednoteNoteId` is exported from `extractors/rednote.js`. Anything that wants to know
  whether a rednote URL is a note must call it rather than testing a route by hand — that
  habit is what produced the two divergent private copies this entry merges.
- **The extractor now reads `/board/<board_id>/<note_id>` as a note URL**, so a single
  capture started from a board card records a `noteId` where it previously recorded none.
  `originalURL` for such a capture is the board-scoped note route, not the `/explore/` form;
  both are live routes for the same note, and `cleanURL` still strips the token from either.
- `bulk-context.js` resolves `/board/<id>/<anything>` to `board:<id>`, so a note route under
  a board still resolves to its board's sweep scope. That leniency is unchanged and is still
  deliberately unpinned (changelog 491), but it is worth knowing that the "anything" now has
  a name.

## Still unverified without another live run

- **Whether rednote's SPA overlays or routes** when the board card is clicked. Both paths are
  handled — Escape, then `history.back()` for a routed note, now for all three routes — but
  which one fires on a real board has never been observed.
- **Whether the tokenised anchor is always present.** The probe found one for the note it
  dumped; a board where some cards render only the tokenless anchor would fall back, log,
  and degrade those notes into `reasons.timeout`.
- **Whether the token in the rendered anchor and the token on the `BulkItem` are the same
  string.** They are not compared, on purpose — a regenerated page token that differed would
  otherwise reject a perfectly good anchor — so the item's `xsecToken` still goes only where
  it always went: into `parseNoteDetail`, for the expanded items' own URLs.

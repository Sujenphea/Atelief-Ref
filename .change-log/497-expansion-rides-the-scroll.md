# 497 — expansion rides the scroll

## Summary

Two rednote defects, both measured live, both with one cause — **expansion ran at the wrong
time** — and therefore fixed together.

**2A.** The board grid is **virtualised**: a console probe on a live board counted **13**
mounted note cards against a feed page of **37–38** and a board of **116**. Expansion ran
over a whole page *after* that page had arrived, by which time the grid had scrolled on, so
`openNote` found no card for most of it. 495 made that visible — `expanded 13 of 116; 103 had
no card on the page to open` — and did not fix it.

**3B.** Nothing was yielded until the **whole page** had been expanded (`items = await
expandItems(items)`, then the yields). At ~2.4 s of pacing plus up to 8 s of waiting per
note, that is **two to five minutes before the first item saves**, and a sweep interrupted in
that window saved nothing at all.

The insight is that **the scroll already mounts cards as it goes**. Expansion now rides it:
work a page's notes in feed order, open the ones whose cards are mounted *now*, yield each
note the moment it is answered, step the viewport down one screen, ask the rest again —
conceding a note to its cover only once the pass has walked the whole page and so has
demonstrably been past it.

> **Index.** This entry is 497. 488–496 are taken; indices are never reused.

## The trap, and how it is made impossible rather than avoided

Expansion **replaces** a note's cover with its children. Yield both and the same picture is
ingested under two keys — `<note_id>` beside `<note_id>:0` — with a dedup-skip that cannot
see the duplicate. That is exactly what T5a refused video notes over and what T6c chose
`<note_id>:v` to avoid.

A single-pass expansion could not make that mistake: each note was visited once, in one loop,
and left with one answer. **A pass that asks a note again after every scroll can** — and so
can one that meets the same note on two pages, which a board shifting under a paging sweep
demonstrably does.

So it is prevented in two places, structurally rather than by rule:

- **The expander keeps a ledger.** Every arm of `attemptNote` ends in one `finish(noteId,
  items)`, which is the only place a note with an id is ever settled, and it records the note
  as done. A note that is already done yields **nothing** on any later sighting — not its
  children again, and above all not its cover. `retireNote` and `failNote` check the same
  ledger before conceding.
- **The loop settles or keeps, never both.** An entry leaves `pending` at the instant it is
  settled, and only a settled verdict produces items. An ask that found no card returns a
  verdict carrying no items at all, so there is nothing for a caller to leak.

The lethal case is pinned end to end: a note expanded on page 1 and met again on page 2 with
its card gone is **not** conceded to a cover on top of its nine images.

## What changed, file by file

**`intercept-source.js` — the shared seam, changed by EXTRACTION only.** `enumerate` is now
`pages()` plus X's per-page `expandItems` and the item-level yield. `pages()` is the queue,
the auto-scroll round, the stall and the fatal route, one page at a time; it is the *same*
loop, in the same order — a page is yielded, the consumer's body runs, and an `endOfFeed`
page ends the generator afterwards.

**The shared-seam decision, and why this one.** Two routes were credible: teach the seam an
optional streaming/expansion strategy, or give rednote its own enumerate loop. This is the
second, with the genuinely common part shared rather than copied.

Everything in the new loop is rednote's policy — reachability, retirement, the per-note
degrade, the ledger, a walk down a virtualised grid — and none of it is a branch X would ever
take. Teaching the seam about them would put rednote-shaped conditionals in the file every X
sweep runs on, which is the largest blast radius available. But *copying* the queue, the
scroll round, the stall and the fatal route into rednote would be worse in a different way:
those are **safety decisions** ("a wall is not an end", "a challenge halts resumable"), and a
second copy of a safety decision is the one that quietly stops agreeing with the first.

**X is protected by construction and by test.** `enumerate` is byte-for-byte the loop it was,
one level down; `twitter-source.js` is untouched; `expandItems`, `onExpandFailure` and
`isFatalExpandFailure` still mean exactly what they meant. Every X and seam test passes
**unchanged**, `twitter-thread-integration.js` included, and none was edited.

**`rednote-detail-client.js` — the expander gains a per-note seam.**

- `attemptNote(item)` — one ask at one note, returning a *settled* verdict (its whole
  contribution) or *pending* (no card; ask again after the next scroll).
- `retireNote(item)` — the pass concedes: the cover, `unreachable`, `no_note_card`.
- `failNote(item, error)` — the ask threw something that is not a refusal: the cover, and
  `degraded`, because 495's split is "could not reach it" versus "reached it and it did not
  answer" and a throw is firmly the second.
- `expandItems` **survives, unchanged in behaviour**, built on those three: it is one ask per
  note with no scroll in between, which is precisely what expansion did before this. Every
  test written against it still passes without edit.
- `canOpen` — the same `findLink`, asked *before* the pacing gap is paid. A note with no
  mounted card now costs **nothing**: no gap, no click, no budget, no counter.
- `createPageStepScroller` — the walk. `scrollTo(0, scrollY + 0.8 × innerHeight)`, `false`
  when already at the foot (and it still nudges `scrollHeight` there, because that is the
  gesture the infinite scroll listens for).

**Three counters moved, and each move is the difference between a truthful number and a
multiplied one.** `attempted` is counted per **note**, not per ask, or the denominator of
`expanded N of M` would count the pass's own diligence. `unreachable` and `no_note_card` are
counted at the **concession**, not at each miss, or a board of 116 walked four times would
report hundreds of unreachable notes. The **budget** is charged where a note-open actually
happens — after `openNote` returns true — or a virtualised board would spend its whole
400-note ceiling on cards that were never there, and spend it again after the next scroll.

**`rednote-source.js` — the streaming pass.** `expandPage` runs the rounds; `expandingItems`
is the seam's pages, each expanded in scroll order. A refusal is re-raised (the sweep halts
resumable); any other throw degrades **that note** to its cover and reports it — where it
used to take its whole page of 37 notes down with it.

**`config.js`** — `NOTE_REACH_STEP_RATIO` (0.8), `NOTE_REACH_SETTLE_MS` (600),
`NOTE_REACH_ROUNDS` (12). Like the feed reset's numbers and unlike `noteOpen`'s, they are
**not** threaded through `PLATFORM_PACING`: they describe one SPA's one virtualised grid,
there is no second platform to vary them for, and a second access path would add nothing but
somewhere for a typo to fall back to a default and look like it worked.

**`bulk-controller.js`** — wires the expander itself (not its page hook) and, only when notes
are being opened, the walk.

## What the cover pass does

**Nothing here reaches it.** With `expandNotes` off there is no expander, so no note is
opened, no card is looked for, and the board is paged by the same single jump to the foot of
the document it always was — the pass verified live against a real 116-note board. The step
scroller is built only for an expansion sweep, and a `scrollStep` handed to a cover sweep is
never called. Asserted, from the source and from the controller's own wiring.

## Everything 392dc8d, d927083, 33632bd, T6c and R14 established

| | how it survives |
| --- | --- |
| **the feed-start guard** (`isFirstBoardFeedRequest`, `RednoteFeedStartError`) | untouched. It fires in `start()`, **before** anything is pulled from the seam, so a refused sweep still opens **zero** notes — and that is still asserted |
| **the in-page reset** and its held responses | untouched; the hold, the grace, the scoped evidence and the memoisation are all where 494 left them |
| **`unreachable` vs `degraded`, `attempted`, `partial`** | kept, and made *more* truthful: `unreachable` now means "still no card after the pass walked the whole page" rather than "no card at the one instant we looked". `partial` is unchanged in rule and in meaning |
| **`refused` / `streamRefused` make no sweep partial** | unchanged; `resolveVideo` still decides whether a video note is opened at all |
| **`<note_id>:v` registers as an expanded child** | unchanged, and now also covered by the cover-or-children invariant asserted over a whole mixed sweep |
| **the note-level pre-check** (R14 / T5b) | unchanged, and still the **first** arm after the id — a known note is skipped before an ask, a gap or an open is spent |
| **the budget** (`NOTE_OPEN_BUDGET = 400`) | still a ceiling, still finishes the cover pass cleanly. A note past it needs no card, so it is settled on sight and **the walk is never spent looking for it** |
| **a 461 mid-expansion** | still fatal, still `isFatalExpandFailure`, still a resumable halt — now asserted on a note reached only *after* a step, not just on the first note of a page |

One consequence is stated rather than hidden. A refusal partway through a page used to
discard the notes ahead of it, because the page was expanded and only then yielded. A
streaming pass has already relayed them. The safety property is untouched — nothing is
relayed **after** the refusal, and the pass stops opening notes the moment rednote says no —
and it is the same trade the board feed's own fatal route makes one level up ("what arrived
before the refusal is kept"). Refusing to yield them would mean holding a whole page back to
preserve the option of discarding it, which is the 3B block being removed. The test that
asserted "nothing at all was relayed" now asserts the real boundary, with the reasoning in
the test.

## What the timing looks like now

The first note of the first page is at the top of the board, where the viewport starts, so
its card is mounted. It is opened, answered, and **yielded** — one pacing gap, one settle and
one detail response, **a few seconds** — rather than after every note on the page has been
opened. Asserted as *interleaving*: relays appear among the opens rather than all behind
them, and the first thing saved is the first note's first image.

## Files changed

`extension/src/intercept-source.js` (`pages()` extracted; `enumerate` rebuilt on it, X's
behaviour unchanged), `extension/src/rednote-detail-client.js` (`attemptNote`, `retireNote`,
`failNote`, the ledger, `canOpen`, `createPageStepScroller`; `expandItems` rebuilt on the
first two; `findLink`'s doc comment brought up to date), `extension/src/rednote-source.js`
(`expandPage`, `expandingItems`, the `expander` / `scrollStep` / reach options),
`extension/src/config.js` (three reach constants), `extension/src/bulk-controller.js` (the
wiring).

`extension/src/twitter-source.js`, `twitter-detail-client.js`, `twitter-thread.js`,
`bulk-twitter.js` and `popup-view.js` are **untouched**.

Tests: `intercept-source` (+5, `pages()` as a seam), `rednote-detail-client` (+15, the
per-note seam, the ledger, `canOpen` and the walk), `bulk-rednote-integration` (+11, the
streaming pass through the real parser, real seam, real expander and real engine, against a
page faked as a **virtualised grid** rather than as a document where every card is always
there), `bulk-controller-bootstrap` (+2, the driver's own wiring — the one seam nothing else
reaches).

## Verification

`npm test` 961 → **994 total, 991 pass, 0 fail, 3 skipped** (the 096 corpus and page-signal
fixtures, still not rednote's). `node scripts/drift-check.js` prints `No drift`, all nine arms
pass, and it still exits **2** on the X/Instagram/Pinterest fixture-staleness arm, which
pre-dates this change.

Twenty-four deliberate breakages, each failing the tests that name it and no others:

| mutation | fails |
| --- | --- |
| the `endOfFeed` page is dropped instead of yielded | 46 |
| `pages()` never ends the feed | 69 |
| an ask that finds no card ends the note (no retry) | 3 |
| a settled note can still be conceded to a cover | 2 |
| a settled note is re-expanded when it is met again | 3 |
| `attempted` counts asks, not notes | 2 |
| a conceded note is not counted `unreachable` | 9 |
| the budget is charged before the click, not after it | 4 |
| `canOpen` is ignored — every ask pays a pacing gap | 1 |
| a note that threw is filed as `unreachable` | 2 |
| the pass never steps — one ask per note, as before | 6 |
| the leftovers are never conceded — they vanish | 4 |
| an unreached note is dropped instead of kept pending | 7 |
| the round ceiling removed | 1 |
| a refusal mid-expansion degrades instead of halting | 2 |
| a degraded note is reported as the whole page | 1 |
| expansion is never applied at all | 20 |
| the walk steps a whole viewport | 1 |
| the walk never admits it is at the foot | 3 |
| the walk stops nudging the paging scroll at the foot | 2 |
| the live driver says every note's card is mounted | 3 |
| `canOpen` drops its id guard | 1 |
| the controller wires no walk | 1 |
| the controller wires no expander | 1 |

**One mutant survived the first round**, and it is the one worth naming: making
`createPageNoteDriver.canOpen` answer `true` unconditionally failed **nothing**. The
per-note seam was tested through injected fakes everywhere, so the *live* driver's new
fast-path — the thing that actually decides whether a note costs a pacing gap on a real board
— had no test at all. Three were added (it agrees with `openNote`, it guards the id before
building a selector, it never throws into the sweep) and it now fails three; a second
mutation on its id guard fails one.

**One mutation hung instead of failing.** Removing the round ceiling made the walk loop for
ever, and a hanging suite reports nothing. The test was rewritten so the fake page *throws*
past a bound — the same shape as the expander's "the note-open wait never gave up" guard — so
the ceiling's absence is now a legible failure rather than a stall.

No mutant survives. Every mutation was reverted before committing.

## Migration notes

- **A rednote expansion sweep now walks each page.** The board scrolls down a screen at a
  time while notes are being opened, instead of jumping to the bottom once per page. The user
  will see this. It happens **only** when *Open each note* is on.
- **Items now save as the sweep goes.** The first note saves seconds in, not minutes. A sweep
  stopped halfway keeps everything settled up to that point.
- **`createRednoteSource` takes `expander` instead of `expandItems`**, plus `scrollStep`,
  `reachSettleMs` and `maxReachRounds`. Omit `expander` and the source is the cover pass,
  exactly as before.
- **`createNoteExpander` gains `attemptNote` / `retireNote` / `failNote` and a `canOpen`
  option.** `expandItems` is unchanged in behaviour and every caller of it keeps working.
- `result.expansion` keeps every field 495 gave it, with the same meanings. `unreachable` will
  be a **smaller** number on a real board, which is the point.
- Nothing in the sweep's UI, spec, messages or storage changed.

## Still unverified without another live run

- **Whether the walk actually mounts the cards.** Everything above is true of a grid modelled
  as a sliding band of mounted ids. What a real virtualiser does with a 0.8-viewport step and
  a 600 ms settle has **not** been watched. Too small a step costs rounds; too large a step
  skips a band and those notes are conceded — which degrades to covers and is reported, never
  to a wrong capture.
- **The number that replaces "13 of 116".** The whole point is a bigger ratio, and it has not
  been read off a real sweep. That reading is also the check that the walk is wired to what
  happens rather than to what the tests simulate.
- **Whether stepping still triggers the page fetch.** The walk always ends at the foot of the
  document and nudges `scrollHeight` there, which is the same gesture the cover pass makes —
  but the cover pass is what was verified, and arriving at the foot in stages is not literally
  the same event. A board that stopped paging would show up as rednote's stall (a resumable
  halt), never as a truncated board recorded complete.
- **How long a full expansion sweep now takes.** More notes are actually opened, and each one
  is still paced — so a board that used to expand 13 notes and finish will now expand many
  more and take proportionally longer. The budget still bounds it at 400 opens.
- **`NOTE_REACH_SETTLE_MS` = 600 ms.** Reasoned from a mount being more work than a route
  change's first paint, and unmeasured. Too short shows up as notes conceded that were about
  to mount.
- **What `canOpen` costs on a real page.** It is a `querySelectorAll` per pending note per
  round — cheap in principle, unmeasured against a document holding a whole board's markup.
- **Whether the walk and a note-open's own scroll restoration cooperate.** `closeNote` puts
  the viewport back where the open found it, which is where the walk left it, so in principle
  the walk's position survives every open. On a grid that rebuilds around a different offset,
  it may not.

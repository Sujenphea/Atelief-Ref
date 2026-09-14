# 499 — a story has an id, so it was a board

## Summary

`checkBoards` asked two things of a Pinterest boards list: that it held at least one
board, and that each board had an `id`. Both are true of responses that are **not boards
lists**, and today one of them was handed to the canary by accident.

A user supplied the wrong Pinterest file to `--pinterest-boards` — the
`board_ideas_preview_detailed` placeholder a board page opens with (`endpoint_name:
v3_board_pins`, a `data[]` that is one `type: "story"` container, **zero boards**). The
canary printed:

```
✔ Pinterest boards list — boards=1
```

`parseBoardsPage` had produced one entry from the story container:

```json
{ "id": "6733671870646100908", "name": null, "url": null }
```

A story has an id, so the check passed. The real list (`v3_user_profile_boards_feed`,
four `type: "board"` rows) reports `boards=4` with real names. **Same verdict, opposite
truth** — and the ✔ is the worse half: the canary's only job is to say whether the shape
the drivers depend on is still there, and it said yes about a response that has none of
it.

Found by a user sending the wrong file, not by a test. That is the second time this class
has surfaced on this branch: 491's `platform-registry.test.js` asserted every *refusal*
carried a message and never that any platform *accepted* a real page, so a resolver that
refused everything passed. A check that only verifies the negative — "not zero", "not
missing an id" — cannot tell the thing it is looking at from the thing it is looking for.

> **Index.** This entry is 499. 497 and 498 are held by concurrent, unrelated sessions;
> indices are never reused.

## It was not one wrong file, it was the whole family

The overwritten placeholder is not the only response that walked through. Both files the
user actually had on disk pass the **pre-499** check, run verbatim:

| `resources/` file | what it is | pre-499 verdict |
| --- | --- | --- |
| `02-pin-boards-list.json` | the real boards list, `v3_user_profile_boards_feed`, 4 boards | `ok, boards=4` |
| `02-pin-boards.json` | a board **feed**, `v3_board_pins`, **25 pins** | `ok, boards=25` |
| the `board_ideas_preview_detailed` placeholder | one story container, **0 boards** | `ok, boards=1` |

A pin has an `id` too. The check could not tell a boards list from a page of pins, from a
page of one story — three different endpoints, one ✔. Post-499 the first passes and the
other two fail by name.

## The placeholder fixture is COMPOSED, not captured

`02-pin-boards.json` was overwritten with the board feed during the session, so the
placeholder that triggered this **is no longer on disk** and nothing in `resources/` can
re-derive it. The fixture in `drift.test.js` is therefore reconstructed from the verdict
it produced — the id is the one `parseBoardsPage` yielded from it, the `type`,
`story_type` and `endpoint_name` are from the report, and everything else is minimal on
purpose. It says so in a comment above itself, and it lives **inline** rather than in
`test/fixtures/`, which is the distinction `drift-check.js`'s `FIXTURE` comment draws:
a committed fixture answers "does a response the platform sent TODAY still parse", and
inventing one and presenting it as captured is what that rule exists to prevent. The
real-shaped four-board page beside it is composed too, from the live capture's shape.

**No file under `test/fixtures/` was touched** — a concurrent session is refreshing the
Pinterest live fixtures.

## Both, and the split is not arbitrary

### The parser: a story is not a board

`parseBoardsPage` filtered on `board && board.id` alone, so anything in `data[]` with an
id became a board. It now also asks `isBoardEntry`, and the evidence for the rule is in
this repo rather than in a guess: Pinterest **interleaves non-board modules into a board
resource's `data[]`**, and `pinterest-boardfeed-live.json` carries a `type: "story"` /
`related_interests_module` row beside its 24 pins. `checkBoardFeed` already learned this
and excludes those entries from its denominator — the boards path simply never did.

An entry with **no** `type` still counts as a board, the same direction `checkBoardFeed`
chose for pins: *if we cannot tell what it is, it has to parse or we hear about it.* A
Pinterest rename of `type` must not silently empty every boards list; it surfaces through
the name/url rules below instead. Both directions are pinned.

A url-less entry that still declares `type: "board"` is **kept, not dropped**. Dropping it
would disguise a renamed `board.url` as "the account has fewer boards" — the exact
degradation this entry is about — and keeping it is what lets the check name the field
that moved.

### The check: what a consumer actually needs

Derived by tracing the consumers, not by picking a plausible-sounding rule — and the
trace's first finding was uncomfortable: **`enumerateBoards` has no production caller.**
The board-picker its doc comment promises does not exist; the popup resolves a single
board from the tab URL plus the Collage href (`bulk-context.js:160-174`) and synthesizes
`boardUrl` from the path, never from the API. So the requirement cannot be read off a
live call site, and is read instead off the only code path a board object can reach:

- **`url` is load-bearing.** It is the only field that makes a board sweepable.
  `buildBoardFeedURL` puts it in **both** `source_url` and `board_url`, and
  `url.searchParams.set("source_url", null)` stringifies to the literal string `"null"` —
  a malformed request to Pinterest, **no throw**, nothing to see. Verified by reading
  `buildResourceURL`, not assumed.
- **`name` is the other half of the parser's stated contract** (`{ id, name, url }`, the
  name of its own test) and the only human label the response carries. `popup-view.js`
  labels rednote off the id precisely because that platform sends no name — *"an id is
  honest; an invented name is not."* A picker has nothing to fall back to; a naive
  `` `Sweep board: ${board.name}` `` renders `Sweep board: null`.

Both are required of **every** board, not "some" — unlike `checkTimeline`'s media rule,
where a text-only tweet legitimately lands media-less. Every board in the live capture
carries both, and a Pinterest board cannot exist without a name and the slug url derived
from it. The two partial-degradation tests are what make that word load-bearing; without
them a `some` rule survives (see the mutation table).

And a **coverage denominator**, computed from the raw `data[]` the way
`checkInstagramSaved` computes its fan-out from Instagram's own declared count, so that
"the parser dropped 3 of 4 boards" cannot read as "a 1-board account".

`isBoardEntry` is **exported and imported**, never respelled in `drift.js` — the rule 496
set when it exported `hasTransform`. A private copy goes on agreeing with the parser
until the parser moves, which is the one mutation below that survives.

## `bookmark` is reported and deliberately NOT required

The live committed fixture comes back `hasBookmark=false`. Unlike a board feed, a boards
list legitimately fits on one page, and `enumerateBoards` reads a missing bookmark as
end-of-feed — correctly. Asserting a cursor here the way `checkBoardFeed` does would have
failed the real capture. It is a signal, not a problem.

## The sibling checks do not share the weakness

Audited, and **nothing else was changed** — three of the four had already been hardened
against precisely this, which is what made `checkBoards` the outlier rather than the
pattern:

| check | coverage rule | per-entry usability rule | verdict |
| --- | --- | --- | --- |
| `checkTimeline` | every tweet entry must map to ≥1 item; per-media id uniqueness | some item has a `mediaUrl` (a text-only tweet is legitimately media-less); Bottom cursor | **sound** |
| `checkThreadDetail` | chain ≥ 2, one permalink, contiguous `carouselIndex` | author, `threadId`, no surviving `threadHint` | **sound** |
| `checkBoardFeed` | every entry that *claims* to be a pin must map, modules excluded from the denominator | id + image via `mapPinterestPin`; bookmark required | **sound** — and it is where the `type` rule came from |
| `checkInstagramSaved` | fan-out from IG's **own** `carousel_media_count`, so expected and actual cannot drop together | `mediaUrl` on every item, `videoUrl` on a reel, route matchers, no challenge misfire | **sound** |
| `checkRednoteBoard` | mapped items must equal `data.notes.length` | origin host, no transform directive, signed fallback, `authorName`, terminator, route matcher vs telemetry | **sound** |
| `checkBoards` | *none* | *id only* | **the defect** |

The one adjacent gap worth naming and **not** fixed here: `checkBoardFeed` requires a
`bookmark`, which is right for a mid-feed capture and would be wrong for a terminal page.
No capture has hit it, changing it would weaken a rule that is currently working, and it
is a different question from this one.

## Files changed

`extension/src/bulk-pinterest.js` — `isBoardEntry` (new, exported), the `parseBoardsPage`
filter, and both doc comments.
`extension/src/drift.js` — `checkBoards` rewritten (coverage denominator, name, url,
signals), `isBoardEntry` imported.
`extension/test/drift.test.js` (+9), `extension/test/bulk-pinterest.test.js` (+5).

No fixture under `extension/test/fixtures/` was modified. No `.docs/` file was touched.

## Verification

`npm test` 961 → **975 total, 972 pass, 0 fail, 3 skipped** (the 096 corpus and
page-signal fixtures, not this change's). `node scripts/drift-check.js` prints `No drift`,
all nine arms pass, and it still exits **2** on the X/Instagram/Pinterest
fixture-staleness arm, which pre-dates this change.

The boards arm now reports the shape instead of a bare count:

```
✔ Pinterest boards list — entries=4 modules=0 boards=4 named=4 addressable=4 hasBookmark=false
```

and run against the board feed the user also had on disk:

```
✘ Pinterest boards list (live: resources/02-pin-boards.json) — DRIFT:
    · no boards among 25 entries — every one is a non-board module (is this a boards list at all?)
```

Nine deliberate breakages of `src/`, each failing the tests that name it and no others:

| mutation | fails |
| --- | --- |
| **the shipped defect** — pre-499 parser + pre-499 check | 10 |
| `isBoardEntry` dropped from the parser filter (a story is a board again) | 4 |
| `isBoardEntry` made strict — an untyped entry is not a board | 3 — including the tolerance test, which is what that direction is for |
| the `name` rule dropped | 2 |
| the `url` rule dropped | 2 |
| the parse-coverage denominator dropped | 1 |
| name/url asked of SOME board rather than every | 2 — both partial-degradation tests, and **nothing else** |
| the denominator counting every entry rather than board entries | 2 |
| a private copy of `isBoardEntry` in `drift.js` instead of the import | **survived — recorded, not chased** |

The survivor is the same class 496 recorded: a copied predicate and an imported one agree
at any single point in time, so no test can tell them apart today. The import is what
stops them disagreeing *after* the parser moves, and that is not a property a test can
hold. It costs nothing and is kept.

The `some`-instead-of-every mutation survived the **first** run, with name and url
stripped from all four rows — three good rows would have covered for a fourth and a list
that was 75% sweepable would have printed ✔, which is this entry's own defect one level
down. The two partial tests were written to kill it and do. No mutation failed a test
outside `checkBoards` / `parseBoardsPage` / `isBoardEntry`, and every one was reverted
before committing.

## Migration notes

- **`checkBoards`'s `signals` changed shape.** `{ boards }` → `{ entries, modules,
  boards, named, addressable, hasBookmark }`. `boards` keeps its meaning and its name;
  the rest are new. The CLI prints signals generically, so nothing needed rewiring, but a
  reader comparing today's line to an old one will see more fields.
- **`parseBoardsPage` now drops declared non-boards.** A caller that relied on getting
  every `data[]` entry with an id back gets fewer. There is no such caller: the only
  production consumer is the canary, and `enumerateBoards` is called from one test.
- **`isBoardEntry` is a new export** of `src/bulk-pinterest.js`.
- **A boards list that parses but is unnameable or unaddressable is now DRIFT**, where it
  used to be ✔. If Pinterest legitimately starts sending nameless boards, this fails —
  and that is the intended direction: it should be a conversation, not a silent pass.

## Still unverified

- **Whether `BoardsResource` itself ever interleaves a module.** The interleaving is
  proven on `BoardFeedResource` (the live capture) and on the board page's opening
  placeholder; no `BoardsResource` capture in `resources/` carries one. The filter is
  coverage for that, and costs nothing on a page that has none.
- **Whether a live boards list can legitimately carry a nameless board.** Every board in
  the only real capture has a name; Pinterest's UI requires one at creation. Unverified
  for the quicksave board specifically, which no capture includes.
- **Whether the placeholder actually reaches `BoardsResource` in normal operation.** It
  arrives on `v3_board_pins`, so a correctly-wired sweep would never feed it to
  `parseBoardsPage`; a user with two files open did. The parser filter is right either
  way, but the runtime blast radius is "the canary lied", not "a sweep broke".
- **A committed fixture for the placeholder.** None was added, for the reason in the
  section above. If one is wanted, the shape is in `drift.test.js` and it needs a real
  capture to replace it — see the report.

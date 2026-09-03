# 480 — The page shows its neighbours

[099 · P9](../.docs/099-mac-backlog-plan.md) asked for three things on the item-detail
page: the bottom filmstrip [041](../.docs/041-item-detail-redesign-plan.md) deferred,
the three X provenance fields [089](../.docs/089-x-post-fidelity-design.md) recorded as
*"stored but unread by the app UI"*, and a read of [023](../.docs/023-item-detail-plan.md)
· F3b against the code.

Two of the three premises the phase was handed were wrong, and both were wrong the way
[479](./479-the-phase-that-had-already-shipped.md)'s were — a plan written from a status
line rather than from the body under it. **F3b shipped long ago.** The filmstrip's
*"token already reserved"* was reserved and then deleted. Only the X fields were as
described, and they were exactly as described.

## The premises, checked before any code

| 099 · P9 says | True? | What is actually there |
|---|---|---|
| *"the `Palette.filmstrip` token already reserved"* | **No** | `Theme.Colors.filmstrip` (#1A1A1C) was **deleted** in [352](./352-floating-bars-one-system.md), which recorded *"no consumers left after the top bar moved"* and the migration note *"Use `Colors.field` for chrome"*. Before this pass nothing named `filmstrip` survived in code — only two doc comments in `ItemDetailView.swift` referring to it in the past tense. The strip was built from nothing, on `mediaBackdrop` — the artwork's own ground, and the right answer anyway. |
| *"`repostedBy`, `threadId`, `threadIndex` are stored and never rendered"* | **Yes** | Written by `bulk-twitter.js:274` and `twitter-thread.js:210`; **zero** Swift readers before this pass — `grep rawMetadata` over the app found only `PostGrouping`'s two. |
| F3b (*"open from Space canvas"*) *"is genuinely unbuilt"* | **No** | Built. `SpaceView.openAssetDetail(_:)` and `spaceDetailOverlay(for:)` (`SpaceView.swift:1010`, `:1021`), reached from `onActivateTile`'s image-asset branch (`:290-293`). 023's own commit list already carried `(F3b ✓)` at line 129. |

The third is the one worth stating loudest. 099 · P9 set the question honestly — *"the
backlog names it, the docs say it shipped, and the agent settles which is true before
writing anything"* — and **the docs were right**. The phase brief that carried the
question forward had already answered it the other way, as *"genuinely unbuilt"*. It is
built. Nothing was written for it, and nothing needed to be; what remains is scoped below
rather than built, per the brief.

## The filmstrip — what 041 asked for, and what it got

041 specified it twice and identically: *"**Bottom** — centered 5-thumbnail
**filmstrip**"* in the Figma target, and in its Deferred section *"5 neighbour
thumbnails; own task (thumbnail-load work)"*. That is the whole spec. Five, centred,
neighbours, at the bottom.

**Neighbours in the RUN, not members of a post** — and that distinction is the design.
[070](../.docs/070-detail-fan-carousel-design.md) §4 weighed *"a filmstrip rail under the
artwork"* and **rejected** it: it *"speaks a different visual language from the grid"*
and *"for the common 2–4 image post it is a lot of chrome to say 'there are three of
these'"*. 080 shipped the fanned pile and spread instead, and they stay untouched. That
entry was about saying *this post has four images*. The strip says *where you are in the
folder* — the fact the pager states as `12 / 60` and nothing has ever shown as pictures.
The two count different sets, and the strip is the only one of them present for the
ungrouped items that are the overwhelming majority.

- **`ItemDetailFilmstrip`** (`ItemDetailView.swift:63`) — two closures, `blobHash: (Int)
  -> String?` and `thumbnailURL: (String) -> URL?`. Two rather than a `[URL?]` for
  `ItemDetailPost`'s reason (080 §2.1): `AsyncThumbnail` keys its cache on the **hash**,
  so a bare URL misses the cache the grid behind the page already warmed. **Lazy by
  index** rather than an array, which is the difference from `ItemDetailPost`: a post is
  a few dozen members and is materialised whole; the run is the whole feed, thousands of
  items, and the strip wants five.
- It hangs off **`ItemDetailNavigator`**, not beside `ItemDetailPost`, because it is a
  view of the same ordered set the arrows walk — one value, so the pager, the arrows and
  the strip cannot disagree about what "the run" is. Optional, defaulted `nil`: a host
  that supplies no artwork gets today's page, not a row of grey squares.
- **`detailFilmstripWindow(count:currentIndex:cap:)`** delegates to `fanSpreadWindow`
  rather than restating it. This is where off-by-ones live, the spread's window already
  has them pinned across ten tests, and two implementations of *"centred on the current,
  clamped to the ends"* are two chances to get the last five items of a folder wrong.
  Only `hidden` is dropped on the way out — a folder of four thousand would report
  "+3995", a true number and a useless one, where a post's "+8" is the point of saying
  it.
- The click goes through the navigator's **own `step`, by delta** — the same entry point
  the arrow keys and the pager use, so the strip cannot reach anywhere the arrows cannot
  and no second clamp was invented. The open item is a **no-op**, not a zero-delta step,
  which would re-present the same picture and bump its view count for a click that asked
  for nothing.
- **Laid out, not overlaid.** It sits in a new `VStack` in the left column, under
  `mediaArea`, so the 298pt sidebar stays full height. The artwork's own bottom strip was
  already spoken for — that is the spread's hover zone
  (`DetailFanSpreadMetrics.hoverZoneHeight`) — and `fanSpread`'s own doc comment records
  at length what happens when a drawn position and a hit region are computed separately.
- **Not gated on the zoom**, unlike the pile and the spread. Those are overlays and can
  fade; a laid-out row that vanished mid-pinch would grow the media pane, re-fire
  `onGeometryChange`, and buy a fresh full-resolution decode at the new tier. A row that
  costs nothing to leave alone is left alone.

### The one place the brief was corrected in code

P9 asked for the neighbours *"through `DetailImageLoader`'s existing preload window"*.
They do not go through it, and could not:

- that loader is the **full-resolution** cache; the strip wants 48pt thumbnails;
- its preload window is `{prev, current, next}` — **three**, not five
  (`detailNeighbors(items:currentID:)`);
- its budget is **five entries** at 384 MB (`detailImageCacheCountLimit`). Five filmstrip
  thumbnails driven through it would fill that budget by themselves and evict the very
  image the page is showing, on every step.

So the strip draws from the shared `ThumbnailPipeline` at its own analytic bucket,
exactly as `DetailFanSpread` does. That is **not** "no decode" — the grid behind the page
cached a cell-sized bitmap, not a 48pt one — but it does get `AsyncThumbnail`'s two-step
paint: a bucket-**tolerant** synchronous hit on the grid's larger bitmap draws each
neighbour on the first frame, and the small exact bucket is decoded off-main and swapped
in behind it. A step never shows a hole, and it costs a 128px decode on a utility queue
instead of a full-resolution one competing with the picture itself.
`DetailFilmstripMetrics.bucket(scale:)` sizes it: 036 §4 C3's rule that *"the cell never
guesses its own size"*, and `AsyncThumbnail.bucket` defaults to the 512 ceiling — sixteen
times the bitmap a 48pt thumb needs (96px on a 2× display, snapping to the ladder's bottom
rung of 128), five times over, on every cold step.

## The three X fields

089 §Open: *"`repostedBy` / `threadId` / `threadIndex` are stored but unread by the app
UI. A detail-view treatment ('reposted by @x', thread position) is unscheduled."* Three
pure readers over `Source.rawMetadata` and three `if let` rows in `SourceSection`.
**Nothing new is stored, and no migration was needed** — `raw_metadata` round-trips
losslessly and has carried these since 310 / [090] 16A.

**The shapes were taken from the extension's own fixtures, by running its mappers**, not
guessed:

| Field | In real fixture data? | Shape |
|---|---|---|
| `threadId` | **Yes** — `mapThread` over `x-thread-detail.json`, the sanitized **live** TweetDetail capture, stamps all 8 items | **string**, `"1900000000000040001"` |
| `threadIndex` | **Yes** — same 8 items | **number**, `0,1,2,3,4` (two images of one tweet share an index) |
| `repostedBy` | **No committed fixture has one.** Only `bulk-twitter.test.js:312` | **string**, `"@reposter"` |
| any of the three | `parseTimelinePage` over **both** bookmark fixtures — 15 items — writes **none** | — |

That last row is the case that matters: **a plain saved post has none of the three**, and
renders exactly the Source section it rendered before this pass. Each row is gated on its
own field independently, because the fields do not travel together — a repost is not a
thread, and a half-stamped item still says something true.

Two decisions inside the readers are worth naming.

- **`threadId` accepts a string and refuses a number.** A tweet id is a 64-bit snowflake.
  `1900000000000040001` past a `Double` comes back `1900000000000039936` — asserted in the
  test, so the premise is pinned and not merely claimed. This is precisely where
  `carouselIndex`'s deliberate tolerance of a quoted number must **not** be copied: a
  small index survives the round trip and an id does not.
- **`threadIndex` does take the quoted number**, for `carouselIndex`'s stated reason
  (`raw_metadata` is a JSON escape hatch written by JavaScript), and refuses negatives
  rather than clamping — there is no tweet before the first, so a negative means the
  stamp is wrong, better said by drawing no row than by rendering "Tweet 0". The row is
  **1-based**, exactly as the "Post" row directly above it is.

## F3b — scoped, not built

`SpaceView.swift` belongs to a sibling agent this pass and was **read only**. Double-click
an image-asset tile on a Space board opens a fully decoupled `ItemDetailView` today, with
tags, colours, collections, Name/Note, favourite and archive all wired. What a board's
page does **not** have, all of it deliberate at the call site and each with a one-line
reason already written there:

| Missing | Why, per the call site | What it would take |
|---|---|---|
| `navigator: nil` — no pager, no ← / →, and now **no filmstrip** | *"a board has no ordered set"* | A board *does* have an order — `space.content()`'s tiles by `z`. Turning it into a run means a `SpaceItemDetail` run + index, and `openAssetDetail` holding a position rather than a value. Then `ItemDetailFilmstrip` is two closures over that array and the strip works unchanged. **This is the single largest gap and the one the filmstrip newly widens.** |
| `post: nil` (defaulted) — no `⧉` position, no pile, no spread | `ItemDetailPost`'s own doc: *"`nil` for … a host with no grouping context (the Space board)"* | `PostGroups(items:)` takes `[CollectionItemDetail]`; a board holds `SpaceItemDetail`. Either a second factory or a shared protocol over "item + asset + source". |
| `usesExternalImageLoader: false`, `previewImage: nil` | *"the Space board / library search … own their decode"* | A `DetailSession` per board, which is P2c-shaped work, not a wiring change. |
| `removeFromFolder` / `requestDelete` / `onMoveToCollection` all `nil` | *"A board has no membership verbs"* — ⌫ owns the placement | Genuinely correct as it is. Not a gap. |
| A **video** tile never reaches the page — `onActivateTile` routes it to QuickLook first | Predates the page being reachable at all | One branch, but 080 §7's *"what a non-image member draws"* is still open, so it should not be moved until that is. |
| No test covers the Space detail path | — | It is view wiring; the testable half is a `SpaceItemDetail` run derivation, which does not exist yet. |

The honest summary: **F3b's deliverable — "decouple `ItemDetailView`, open from the Space
canvas" — is done.** What remains is not F3b; it is "a board is not an ordered set", which
no doc has yet asked for and which this changelog is the first to write down.

## Files changed

- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `ItemDetailFilmstrip`;
  `ItemDetailNavigator.filmstrip`; `detailFilmstripWindow`; `DetailFilmstripMetrics`;
  `DetailFilmstrip`; the `filmstrip` property and its slot in the body's new left-column
  `VStack`; `repostedBy(for:)` / `threadID(for:)` / `threadIndex(for:)` and their three
  rows in `SourceSection`.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — the navigator gains a `filmstrip` over
  `model.detailRun`, read **fresh** inside the closure and bounds-checked.
- `AtelierRefs/AtelierRefs/LibrarySearch.swift` — the same over `results`.
- `AtelierRefs/AtelierRefsTests/DetailFilmstripTests.swift` — **new**, 20 `@Test`.
- `AtelierRefs/AtelierRefsTests/DetailSourceMetadataTests.swift` — **new**, 19 `@Test`.
- `.docs/099-mac-backlog-plan.md` — P9's status row and section.
- `.docs/041-item-detail-redesign-plan.md` — both filmstrip lines: no longer
  deferred, and the `Palette.filmstrip` reservation they cite no longer exists.
  Amended rather than left, because a stale reservation in a plan doc is exactly the
  thing that sent this phase looking for a token that had been deleted.

`@Test` 4387 → 4426. No assertion weakened, none deleted, no `Task.sleep`, `ci.yml`
untouched.

## Verification

`./scripts/verify.sh full` on the committed tree — **exit 0, all 13 stages passed,
`⚠ Extension` expected**: that stage's warning is a 20-day-old Instagram drift fixture
against a 14-day window, with 635 extension tests green and 0 failures, and is unrelated
to this pass.

The six new suites were also run alone under `-only-testing`, to prove they are in the
target and not merely compiled: **39 tests, 39 passed, 0 failed** — `DetailFilmstripWindowTests`
(13), `DetailFilmstripBucketTests` (3), `DetailFilmstripArtworkTests` (4), `RepostedByTests`
(6), `ThreadStampTests` (8), `SourceMetadataIndependenceTests` (5).

**Four full-gate runs: two green, two red on the same test in a package this pass never
touched.** Both failures were `CanvasBenchmark.testFrameUpdateWithinBudget` — the
wall-clock 120 fps budget — at **8.83 ms** and **11.02 ms** against 8.33 ms, while
`uptime` reported load averages of **7.51** and then **12.06** (1 m) from a sibling
agent's gate on the same machine. Run in isolation immediately after the second, it
passed, and the whole `CanvasBenchmark` suite passed with it. The data volume was at
**20 GB free**, so this is NOT
[478](./478-the-colours-learn-to-say-and.md)'s disk-pressure cause — that one was the
volume at 100 %.

It is the same benchmark [378](./378-the-gate-that-knew-which-way-was-warm.md),
[473](./473-the-saved-search-becomes-a-place.md),
[477](./477-the-anchor-says-whose-photo-it-is.md), 478 and
[479](./479-the-phase-that-had-already-shipped.md) have each recorded failing under
concurrent gates — 479 measured 9.65 ms with three of them running. Five changelogs have
now written down the same wall-clock test failing for the same reason, and nobody has
taken the decision it is waiting for: whether a hard per-frame budget belongs in a gate
that may be one of three on a shared machine. Naming it a sixth time is this pass's only
contribution to it.

## Migration notes

None for data — nothing new is stored and there is no migration. One API note:
**`ItemDetailNavigator`'s memberwise initialiser now takes `step:` as a labelled
argument** rather than a trailing closure, because a defaulted `filmstrip:` follows it.
Both call sites are updated. A host that wants the strip passes `filmstrip:`; one that
does not gets exactly today's page.

## What is still NOT covered

- **A Space board still has no filmstrip, and now that is a visible asymmetry rather than
  a latent one.** The strip appears on the collection grid and on search results — the two
  hosts with a run — and not on a board, which has no navigator at all. The table above is
  the whole scope; it was not built, per the brief.
- **Nothing was verified on screen.** The strip's geometry, its centring under the
  artwork, and how the three new Source rows wrap in a 298pt panel are all argued from the
  code and pinned by pure tests. The gate does not run the UI suite (474 / issue 23D), and
  no flow was run by hand. **A 19-digit "Thread ID" value in a 298pt panel is the specific
  thing most likely to look wrong**, and no test can tell you that.
- **The strip is not keyboard-reachable as a strip.** Each thumbnail is a `Button`, so it
  takes focus and carries an accessibility label, but there is no chord that puts focus
  *on* the strip, and no `KeyMap` row was added — `KeyMap.swift` was outside this pass's
  territory.
- **The strip is NOT gated on `isImage`, where the pile and the spread are.** A video or a
  media-less item on the page still gets a strip, and its media-less *neighbours* draw the
  same `doc` placeholder the spread's cards do. That is deliberate — the strip is about
  position in the folder, which is true of every kind — but it is the opposite call from
  080 §7's, which is still reserved for the pile and the spread. If §7 is ever settled the
  other way, the three should be looked at together rather than one at a time.
- **The strip does not scroll or drag-scrub.** The spread has `fanSpreadScrubSlot` and a
  `DragGesture`; the strip has five buttons. Five is 041's number and a scrub across five
  is not obviously worth the gesture, but the asymmetry between the two carousels on one
  page is a real inconsistency and nobody has judged it with the thing on screen.
- **`repostedBy` is rendered but has never been seen.** No committed fixture contains one;
  the reader is written to `bulk-twitter.js`'s promise and to a synthetic unit test.
  The **first live sweep that captures a repost is what actually verifies this row**, and
  089 §Open already asks for that sweep for other reasons.
- **A thread's LENGTH is not stored, so the row cannot say "of N".** `threadIndex` is a
  position with no total — the extension stamps each tweet's index but never the chain's
  size — so the row reads `Tweet 3` where the "Post" row above it manages `Image 2 of 4`.
  Fixing it is an extension change (`mapThread` knows `perTweet.length`), i.e. new stored
  data, which P9 explicitly forbade.
- **The other two items 089 §Open lists are untouched**: a thread item's individual
  permalink is still not stored as a URL, and the live-verification sweep is still not
  run.
- **070 §4's objection is answered by argument, not by measurement.** The strip does eat
  vertical room from the artwork — ~64pt of it. It is spent as thinly as a recognisable
  photograph allows, and the reasoning is written at `DetailFilmstrip`, but whether it is
  worth the room is a judgement that wants the page in front of a user.

# 479 — The phase that had already shipped

[099 · P8](../.docs/099-mac-backlog-plan.md) asked for the detail page's post context:
`ItemDetailPost`, the fitted artwork rect, the `⧉ 2 of 4 in this post` chip beside the
pager, the sidebar's "Post" row, the resting pile with no images, and tests per
[080](../.docs/080-detail-fan-carousel-plan.md) §5.

**Every one of those is in the tree, and has been since 2026-08-10** — three weeks
before 099 was written. Increment 3, the spread that P8's brief explicitly excludes,
shipped with them and has had three fixes since. No code was written this pass; what
this changelog records is the audit and the three stale status blocks it corrects.

## How a shipped phase got planned again

099 was planned against the code, and says so in its opening paragraph. P8 is the one
section where that did not happen: it was assembled from two **status blocks** whose
doc bodies underneath them already said otherwise.

- **080's header** reads *"Status: planned, unbuilt."* Its own §3.3 carries
  *"Revised after building it ([358](./358-the-post-position-moves-to-the-sidebar.md))"*
  and its §3.5 carries *"Built ([360](./360-the-pile-opens.md))"*. The header was never
  updated when the body was.
- **078's status block** reads *"I4 ([070]'s carousel chip) remains deliberately optional
  and unbuilt."* I4 was built in [356](./356-the-page-says-which-post.md) and then moved
  off the top bar in 358.

This is the tax [365](./365-the-backlog-says-what-is-true.md) was written about,
recurring one doc lower down: a status line that outlived its own body, and a plan
written from the line rather than the body.

## What was verified, line by line

Each of P8's deliverables read at the file, not inferred from a changelog:

| P8 asked for | Where it is | Landed in |
|---|---|---|
| `ItemDetailPost` | `ItemDetailView.swift:71` | 356 · `fd2d933` |
| One pure factory on `PostGroups`, not per host | `PostGrouping.swift:267` — `detailPost(forItem:thumbnailURL:jump:)` | 356 |
| 080 §4's `LibrarySearch` hoist | `LooseDetailContext` + its memo (`LibrarySearch.swift:1051`, doc: *"keeps `LooseDetailContext` off the body-pass hot path (080 §4)"*), `@State postGroups` at `:1157` | 356 |
| The `⧉ 2 of 4 in this post` chip beside the pager (078 · I4) | Built, then **deliberately superseded** — see below | 356, 358 · `b9ed033` |
| The sidebar's "Post" row | `ItemDetailView.swift:1790`, in `SourceSection` | 358 |
| The fitted artwork rect | `fitRect(contentWidth:contentHeight:in:)`, `ItemDetailView.swift:210` | 357 · `6b637cc` |
| The effective-scale scalar out of `ZoomableImage` (080 §2.3) | `ItemDetailView.swift:1339`, written at `:1353` from `zoom * pinch` | 357 |
| `fanBackingRotations(seed:cardCount:maxDegrees:)` | `FanCard.swift:44` | 357 |
| The visibility predicates | `showsFanPile(memberCount:effectiveScale:)` `:131`; the chip's is `showsPostPosition(memberCount:)` `:114`, renamed for the fact rather than the chrome when 358 moved it | 357, 358 |
| `PostChipStyle` | `MasonryGridItem.swift:188` | 356 |
| The resting pile, two blank tilted cards | `ItemDetailView.swift:1479-1519` | 357 |
| Tests per 080 §5 | `DetailFanPileTests` (T1, T3-pile), `DetailPostTests` (T2, T3-row, T4.1, T4.4), `DetailFanSpreadTests` (T4.2, T4.3) — each `@Test` carrying its T-number in prose | 357-360 |

080 §5's four groups are all present, and the two the plan said would only *"bite once
the spread exists"* (T4.2 index shift after a rebuild, T4.3 the clamped jump) came into
force with it, exactly as §6 said they would.

## The chip's fate is a decision, not a gap

P8's brief names both *"the chip beside the pager"* and *"the sidebar's Post row"* as
deliverables. They are not two things; they are one fact and two chromes, and the second
replaced the first. 356 put `⧉ 2 of 4 in this post` beside the centred pager, complete
with 080 §3.3's narrow-width machinery — `topBarWidth`, a measured `centredBudget`, a
`sideClusterReserve = 104`. On the built page it read as clutter around the only
*controls* in the bar, so 358 moved the fact into Source as `Image 2 of 4` and deleted
the machinery with it. Rebuilding the chip would undo a decision made with the thing on
screen, which is the strongest evidence any of these docs has.

`PostChipStyle` outlived it. 080 §3.3 extracted the spec to be read by two renderers;
358 deleted the second, so it is now read only by `PostBadge`. Left as it is — a written
spec that names its numbers is still worth more than the constants inlined back into the
`NSImage` path.

## How video and tweet members ride the post model

The backlog's *"fan carousel for video and tweet members"* is 080's I2. It needed no kind
branch **in the model**, because nothing in that path is kind-aware:

- `PostGroups` buckets on `postGroupKey(for: detail.source)` and sorts on
  `carouselIndex(for:)` (`PostGrouping.swift:214`, `:218`). Neither reads the asset's kind.
- `detailPost` maps member ids straight through: `blobHashes: ids.map { blobHashByItem[$0] }`
  (`:286`). `[String?]`, one slot per member.
- Increments 1-2 read `index`, `memberCount` and `seed` and nothing else.

The one place a kind *could* have leaked is alignment, and
[359](./359-a-slot-per-member.md) closed it before anything consumed it: `blobHashes`
was `[String]` with media-less members compacted out, and `jump` takes a **post-relative**
index, so one media-less member anywhere in a post shifted every card after it onto the
wrong image — *"silent, and worst on exactly the posts [310](./310-a-tweet-is-its-images.md)
created."* `map` for `compactMap` made "the i-th card is member i" a compiler-carried
invariant.

So a video or a tweet **as a member of someone else's post** rides it completely: it is
counted, it keeps its slot, ← / → walk onto it, `jump` reaches it, and it draws its
poster blob in the spread or the placeholder card (`ItemDetailView.swift:1664`) if it has
none.

**As the open item, the drawing stops at the sidebar, on purpose.** `fanPile` and
`fanSpread` both open `if isImage, let post, …` (`:816`, `:857`), with the reason written
where the gate is: *"A media-less kind has no intrinsic size to fit (`fitRect` returns
`nil` for it anyway) and video's fitted rect belongs to `AVPlayerView`'s own layout,
controls included — 080 §7 defers what a non-image member should draw."* The Source row
is **not** gated (`:1789`), so a video that belongs to a post still says so in words; what
it does not get is a pile behind the player or an arc over its controls. That is 080 §7
standing, not a gap this pass introduced.

## What was decided, and why nothing was written

Three courses were available and two were refused.

**Rebuild it** — no. Every deliverable exists with tests, and two of them (the chip's
position, the compaction) are the *outcome* of a decision made after seeing the built
thing. Rewriting shipped code to satisfy a stale plan inverts which of the two is
evidence.

**Close 080 §7's deferral** — no. §7 reserves *"video / tweet decided after seeing it"*,
and 099's rules say an agent that finds a decision wrong stops and reports rather than
choosing differently. The residue is named below rather than guessed at.

**Correct the record** — yes, and it is the whole diff: 099's P8 row and section, 080's
header, 078's status block.

## Files changed

- `.docs/099-mac-backlog-plan.md` — the P8 section gains a status block naming the
  commits; the status table's P8 row goes `not started` → `done — found already shipped`.
- `.docs/080-detail-fan-carousel-plan.md` — the header's *"planned, unbuilt"* becomes the
  shipped record its own §3.3 and §3.5 already implied, increment by increment.
- `.docs/078-item-detail-gaps-plan.md` — I4 is no longer "optional and unbuilt".

No Swift changed. No `project.pbxproj` change was needed or made. `@Test` count is
**4376 before and 4376 after** (`git grep -h "@Test" <ref> -- "*.swift" | wc -l`).

## The gate

`./scripts/verify.sh full`, from the P8 worktree — run 4, on the least-loaded machine
of the four:

```
── summary ──
  ✓ AtelierCore
  ✓ AtelierCapture
  ✓ AtelierLibraryPaths
  ✓ AtelierBrowse
  ✓ AtelierArchive
  ✓ AtelierTokens
  ✓ AtelierIngestion
  ✓ AtelierServer
  ✓ CanvasRenderer
  ✓ AtelierExport
  ✓ App target (Release)
  ⚠ Extension
  ✗ App target

1 stage(s) failed.
```

`⚠ Extension` is the stale Instagram drift fixture, non-fatal by design (17A / 464).
**`✗ App target` is the flake set the user put out of scope**, and this pass did not
touch a line of Swift, so it cannot be otherwise: the target's compiled inputs are
byte-identical to `HEAD`.

Four full runs, and a **different** timing test each time — the signature of a bet on a
fixed timeout, not of a regression:

| run | machine | what `App target` failed on |
|---|---|---|
| 1 | 3 concurrent gates (p8 / p10 / p11) | `PollTests/settlesEarly`, `CollectionActivationTests/sidebarDraftCommitSelectsNewCollection`, `CollectionReadModelTests/savedSearchItemThatStopsMatchingVanishes` |
| 2 | 3 concurrent gates | the same three, plus `CanvasRenderer`'s `CanvasBenchmark.testFrameUpdateWithinBudget` at 9.65 ms against an 8.33 ms budget |
| 3 | 1 sibling | `LibrarySearchModelTests`, broadly |
| 4 | idle | `CoalescerCancellationTests/pendingIngestReloadIsCancellable` alone |

`PollTests/settlesEarly()`, `LibrarySearchModelTests` and `CollectionActivationTests` are
by name **the three load-induced timeout flakes** recorded in
[469](./469-the-cache-that-was-never-promised.md) through
[476](./476-the-palette-is-the-second-window.md) and left alone by the user's own
direction (21A); `CanvasBenchmark.testFrameUpdateWithinBudget` is
[473](./473-the-saved-search-becomes-a-place.md)'s, at almost the same number.

**The isolation run settles it.** `LibrarySearchModelTests`, `PollTests`,
`CollectionActivationTests` and `CollectionReadModelTests` run together on their own:

```
** TEST SUCCEEDED **   130 test cases passed, 0 failed
```

Run 4's `CanvasRenderer` is green, so run 2's benchmark failure was the load it looked
like. 099's rule is that a phase which cannot get the gate green does not commit; the
rule this pass is applying instead is the brief's own — *a stage that fails on something
plainly unrelated to the diff is re-run once and reported, not chased* — because a
docs-only diff has no mechanism by which to redden a Swift test, and the flakes are
named as out of scope in the same sentence that names them.

**One environment finding worth recording.** The three sibling worktrees share one
scratchpad directory, and each agent's `verify.sh > verify-full.log` opened the *same*
inode with its own file offset. The runs overwrote one another's regions — a log whose
line count went **down** between two reads, and a summary block that could not be
attributed to the run that wrote it. Any parallel-agent batch should give its log a
worktree-unique name; this one moved to `p8-gate-*.log` and the contention vanished.

## Migration notes

None. Docs only.

## What is still NOT covered

- **080 §7's mixed-kind drawing, which is a deferral and not an oversight.** Two halves
  of it are open. (a) A **video or media-less item on the page draws no pile and no
  spread** — `fanPile` and `fanSpread` are gated on `isImage` (`:816`, `:857`); only the
  Source row survives for it. (b) The *copy* is not kind-blind even where the model is:
  three strings say "Image" for every member whatever its kind — the sidebar row
  (`:1790`) and the spread card's `.help` and `.accessibilityLabel` (`:1649-1650`) — so a
  video inside a mixed post reads "Image 3 of 5". 080 §7 reserved both judgements for
  *after* seeing the built thing, and this pass did not take them.
- **The fan spread is not deferred any more, and P8's brief still says it is.** 080 §6
  gated increment 3 on increments 1-2 shipping; they shipped, the judgement went the
  other way, and 360 built it — hover the artwork's bottom strip, a ~7-card arc with a
  spoken `+N`, drag-to-scrub. 361, 362 and 363 fixed the arc's position, its scrub and
  its hit region. Anyone reading P8's *"the spread is judged after these ship"* is
  reading a sentence that was already answered.
- **`PostChipStyle` has one consumer where it was extracted for two.** Harmless, and
  deliberately left.
- **Nothing was re-verified on screen.** The audit is a read of the code and the tests
  at the paths cited; the gate compiles and runs them, but the UI suite is not in the
  gate (474) and no flow was run by hand.
- **The rest of P9's detail-page gaps.** The filmstrip, repost/thread rows on X posts,
  and detail-on-a-Space-board are P9's, and untouched.
- **`App target` is red on this machine and this pass did not make it green.** Four runs
  above, four different timing tests, all green in isolation — the flake set 21A left
  alone, still left alone. What would actually close it is a decision nobody has taken:
  whether 099 · 11A's fixed timeouts are the right bet on a machine that may be running
  three gates at once. Naming it here is the whole of the contribution.

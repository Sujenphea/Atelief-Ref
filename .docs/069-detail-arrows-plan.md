# 069 — The detail page's arrows

> Prev/next on the item detail page, with carousels in the feed: the keys are dead and
> the chevrons walk a list nobody is looking at. Two unrelated defects, one fix.
> Finishes the migration [307](../.change-log/307-carousel-post-grouping.md) /
> [309](../.change-log/309-an-opened-post-opens-in-one-place.md) started.

## 1. The problem

Two symptoms, reported together because carousels are where they become visible, but
they share no mechanism:

1. **← / → do nothing.** The image doesn't move and the "N / total" counter doesn't
   change.
2. **The ‹ › chevrons do move — through the wrong list.** They step image-by-image into
   carousel members the grid isn't showing as tiles, in raw feed order.

That the two controls disagree is itself the tell. The chevron's action *is*
`navigator.step(±1)`, and the keyboard shortcut is declared on that same `Button`
(`ItemDetailView.swift:248,256`), so one closure serves both. A divergence can only mean
the key press never reaches the button.

## 2. Root cause 1 — the grid eats the arrows

`MasonryNSCollectionView` takes first responder on the click that opens the detail
("focus follows the click", `MasonryGridHost.swift:966`) and never gives it up: the
detail is an overlay in the same window, not a sheet, and nothing resigns for it. Its
`keyDown` then consumes ← / → unconditionally — `gridKeyDown` → `execute(keyCommand:)`
(`MasonryGridHost.swift:1512`), which returns `true` at `:1537`.

So every press *does* something: it moves the grid's hidden cursor and scrolls the grid
behind the overlay. The evidence is destroyed on the way out — `close()` overwrites the
lead from the session (`CollectionView.swift:1047`) — which is why it reads as a dead
key rather than as a grid that wandered.

This is the lesson [269](../.change-log/269-canvas-tool-keys-are-canvas-keys.md) already
recorded, in almost the same words: *"`keyDown` only reaches a first responder, and an
open editor **is** the first responder — so the canvas's own focus is the gate."* The
detail overlay has no focused view of its own, so it has no gate; a sibling
`keyboardShortcut` is not a substitute.

## 3. Root cause 2 — two lists, one of them unseen

307 and 309 moved every grid-facing subsystem onto `displayItems` — layout, the selection
store's order, the marquee, the reorder solve (`IngestionModel.swift:475-484`). The
detail navigator was left behind on the raw feed:

| | list | order |
|---|---|---|
| the grid draws | `model.displayItems` (`CollectionView.swift:652`) | one tile per post; an opened post's images contiguous, in post order |
| the pager walks | `model.items` (`CollectionView.swift:975`, `:1014`, `:1016-1020`, `:940`) | every image, raw feed order |

So the pager steps into hidden members, in the order 309 explicitly stopped using, and —
once a reorder, a partial move or a re-file has interleaved a post — not even
contiguously: the arrows wander off into unrelated images and come back to the same post
later. The counter is over `items.count`, a total the grid never shows.

The seam is documented at `IngestionModel.swift:446-449` ("The detail overlay steps
through ALL items — including carousel members the grid is hiding"). Only the *sync back
on close* was ever fixed, via `displayTile(for:)`; the stepping never was.

`LibrarySearch` carries both defects in the same shape — the grid draws `displayItems`
(`:826`) while the overlay navigates `search.results` (`:476`, `:1075-1082`).

## 4. The decision — a post is one run

Tiles in grid order, with each post's images opened out contiguously in post order:

```
grid:   [A] [post▸] [B] [C]
detail: A → post#1 → post#2 → post#3 → B → C      "2 / 6"
```

The alternative — one stop per tile, mirroring the grid exactly — makes the counter match
the tile count, but it strands images #2–#4 behind a chip the user has to go back and
click. Opening a post to look through it is the whole point, so the run wins; the counter
counts images, which is what a detail page is paging through anyway.

This is the same sentence 309 wrote for the grid, applied to the page.

## 5. One ordered run, derived once

### 5.1 `PostGrouping.swift`

The run is `collapsed(_:expanding:)` with *every* post opened. Reusing that method rather
than writing a second walk is the point — display order and detail order then cannot
drift:

```swift
/// Every item, with each post's members gathered contiguously at the
/// representative's slot in POST order — the DETAIL page's run (309).
func fullRun(_ items: [CollectionItemDetail]) -> [CollectionItemDetail] {
    collapsed(items, expanding: Set(membersByKey.values.compactMap(\.first)))
}
```

It inherits the all-or-nothing sort (`PostGrouping.swift:171`) for free: a half-indexed
post keeps feed order in the run exactly as it does in the grid.

### 5.2 `IngestionModel.swift`

Derived in `rebuildItemDerivations()` (`:465`) beside `displayItems` — same pass, same
invalidation, so it cannot go stale:

- `private(set) var detailRun: [CollectionItemDetail]` — `groupCarousels ?
  postGroups.fullRun(items) : items`;
- `private var detailRunIndexByItem: [UUID: Int]` + `func detailRunIndex(of:) -> Int?`,
  built with `uniquingKeysWith:` like the neighbouring `assetIDByItemID` (`:487`). This
  also retires the per-body `model.items.firstIndex { … }` scan the overlay runs today.

### 5.3 `CollectionView.swift`

Four sites in `CollectionDetailHost`, all mechanical:

- `:940` — `session.present(detail, in: model.detailRun)`. This list is also the
  session's prev/next preload window (`DetailSession.swift:244-267`), so it has to be the
  list the pager steps or every step decodes a cold neighbour.
- `:975` — `model.detailRunIndex(of: detail.item.id)`.
- `:1014` — `count: model.detailRun.count`.
- `:1016-1020` — bounds-check and `session.step(to:in:)` against `model.detailRun`.

`close()` is unchanged: `displayTile(for:)` already maps a member that isn't on screen
back to its post's tile.

### 5.4 `LibrarySearch.swift`

`rebuildGrouping()` (`:702`) derives the same run over its synthesized items. Search
synthesizes `item.id == asset.id` (`PostGrouping.swift:114`), so the run maps straight
onto `[AssetDetail]`: keep `detailRunIDs`, index the hits by asset id, and hand the
overlay (`:476`) `detailRunIDs.compactMap { … }`, falling back to `search.results` when
the run is empty.

## 6. Giving the page a gate

### 6.1 A focused key catcher

A `DetailKeyCatcher: NSViewRepresentable` (small enough to sit at the foot of
`ItemDetailView.swift`), installed as a zero-size `.background` **only when `navigator !=
nil`** — the Space board's detail has no prev/next to drive:

- backing `NSView` with `acceptsFirstResponder = true`;
- `keyDown` maps `NSLeftArrowFunctionKey` / `NSRightArrowFunctionKey` **without ⌘** to
  `onStep(∓1)` and lets everything else fall through to `super` — the same pure shape as
  `gridKeyCommand(characters:modifiers:)` (`MasonryGridHost.swift:1767`);
- arms first responder on a main-actor hop once it is in a window (the `onHostReady`
  precedent, `SpaceView.swift:741`), remembers the previous responder and restores it in
  `dismantleNSView`;
- **arms once per presentation.** `updateNSView` runs on every step and every zoom, and
  re-arming would rip focus out of the sidebar's Name / Note field mid-edit. Skip arming
  whenever the window's first responder is a field editor / `NSTextView` — which is also
  what keeps arrows editing text while a field is focused, by construction.

No disabled-state mirror is needed: `navigator.step` already no-ops off the ends
(`CollectionView.swift:1016`).

Then **remove** `.keyboardShortcut(.leftArrow/.rightArrow, modifiers: [])` from the
chevrons (`ItemDetailView.swift:248,256`), so a press can never fire both paths. The
`(←)` / `(→)` hints stay in `.help()`; Back keeps `.cancelAction`.

### 6.2 And a gate on the grid

Belt-and-braces, so the grid cannot move behind the overlay even if the catcher fails to
arm:

- `GridHostConfiguration` gains `var isDetailPresented: Bool = false`
  (`MasonryGridHost.swift:37-140`), wired from `model.isDetailPresented`
  (`IngestionModel.swift:290`, already maintained at `CollectionView.swift:937`) at the
  config site `:652`, and from `detail != nil` at `LibrarySearch.swift:826`;
- `gridKeyDown` (`:1479`) returns `false` immediately when it is set.

Two behaviours deliberately survive this. **Escape** still closes the page — returning
`false` is the same fall-through `:1520-1525` already performs. **Delete** still reaches
`gridDeleteCommand()`, because the delete key arrives through the
`deleteBackward:`/`deleteForward:` responder methods (`:318-319`), which bypass
`gridKeyDown` entirely.

## 7. Files changed

- `AtelierRefs/AtelierRefs/PostGrouping.swift` — `fullRun(_:)`
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `detailRun`, `detailRunIndex(of:)`
- `AtelierRefs/AtelierRefs/CollectionView.swift` — the four navigator/session sites,
  `isDetailPresented` into the grid config
- `AtelierRefs/AtelierRefs/LibrarySearch.swift` — run derivation, overlay ordering,
  `isDetailPresented`
- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `DetailKeyCatcher`, chevron shortcuts
  removed
- `AtelierRefs/AtelierRefs/MasonryGridHost.swift` — the config flag and the `gridKeyDown`
  gate

## 8. Tests

- `PostGroupingTests.swift` — `fullRun`: members contiguous at the representative's slot
  in post order; ungrouped items untouched; a half-indexed post keeps feed order;
  grouping off is identity.
- `PostGroupingWiringTests.swift` — on `CarouselRig`, beside the existing *"the detail
  cursor lands on a TILE, never on a hidden member"* (`:323`): the run rebuilds on load /
  toggle / expansion, `detailRunIndex` agrees with `detailRun`, and stepping from a
  post's cover reaches image #2 next.
- `SelectionCellDeltaTests.swift` — the catcher's pure arrow→step mapping, in the style
  of the existing `gridKeyCommand` cases (`:178-203`).

## 9. Verification

1. `xcodebuild test -project AtelierRefs/AtelierRefs.xcodeproj -scheme AtelierRefs`
2. `xcodebuild -scheme AtelierRefs build`, launch, open a collection holding a
   multi-image Instagram post:
   - open the post's tile — ← / → move the image, and the counter tracks;
   - → from the cover walks that post's images in post order, then continues to the next
     grid tile; the ‹ › chevrons do exactly the same thing;
   - close the page: the grid has not scrolled or moved its cursor on its own, and the
     lead lands on the post's tile;
   - click into the sidebar's Name field — arrows move the caret, not the page;
   - repeat in library search (⌘F) with a carousel among the hits;
   - with no detail open the grid's own arrows still work; Escape still closes; Delete
     with the page open still targets the page's own item.

## 10. Shipping

Urgent item, so it goes onto its own branch off `main`, proves itself there, and comes
back in one merge:

1. `git checkout -b fix/detail-arrows` (from `main`, currently clean).
2. Implement §5 and §6, with §8's tests.
3. `xcodebuild test …` green, then the §9 walkthrough in a real build.
4. Commits in `CLAUDE.md`'s format, one per root cause so a bisect can separate them:
   - `fix: detail - arrows reach the page, not the grid behind it`
   - `fix: detail - prev/next walks the post, in the post's order`
   - `docs: detail - changelog for the arrow fixes`
5. `git checkout main && git merge --no-ff fix/detail-arrows` — `--no-ff` so the pair
   stays one reviewable unit in the history.

Merge is local; nothing is pushed unless asked.

Ship with a changelog entry at `.change-log/316-detail-arrows-walk-the-post.md` (316 is
the next free index) covering both root causes, the shared run, and the first-responder
rule this makes explicit.

## 11. After this

[070](./070-detail-fan-carousel-design.md) explores the other half of the complaint: once
the arrows walk the post correctly, the page still never says a post is what you are
walking. That doc proposes bringing the grid's fanned pile and `⧉ N` chip onto the detail
page. It is deliberately not scheduled here — it should be judged against a page whose
arrows already work.

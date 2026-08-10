# 080 — The detail page's fan: settled plan

**Status: planned, unbuilt.** Supersedes the open questions in
[070](./070-detail-fan-carousel-design.md), which stays as written — it is the
exploration, this is the commitment. 070's precondition is met:
[069](./069-detail-arrows-plan.md) shipped as
[316](../.change-log/316-detail-arrows-walk-the-post.md), so the page's ← / → already
walk a post as one contiguous run.

> A review of 070 against the code it proposes to reuse turned up three statements
> that are not true of this codebase, two rationales that do not survive contact with
> `showsFan`, and one pre-existing per-body-pass rebuild that 070 would have doubled.
> The feature survives all of it, smaller and cheaper than 070 assumed.

## 1. What changed, in one paragraph

The resting pile loads **no images at all** — the grid's fan cards carry no artwork,
so neither does the page's. That deletes the thumbnail-cost story from the first two
increments and moves it entirely into the optional spread. In exchange the spread got
more expensive: it owns the blob hashes, a visible card cap, an explicit decode
bucket, and a cold-decode problem that is worst exactly where the feature is most
wanted. Which sharpens 070 §5.4's "3.3 may be unnecessary" from a hunch into a
costed decision.

## 2. Three corrections to 070

### 2.1 `thumbnails: [URL?]` cannot drive `AsyncThumbnail`

070 §3.4 declares the member list as `[URL?]`, then two paragraphs later says
"`AsyncThumbnail` + `thumbnailPixelBucket` are the same loaders `FanCard` uses."
Those are incompatible. `AsyncThumbnail` takes `hash` **and** `url`
(`SharedThumbnail.swift:40-52`), and the hash is the cache key — the load is
`.task(id: ThumbnailKey(hash:bucket:))` over
`ThumbnailPipeline.shared.cachedEntry(hash:bucket:)`. With URLs alone every fan card
misses the shared cache and re-decodes.

The shape to copy already exists: `FanCard` takes `recentBlobHashes: [String]` plus a
`thumbnailURL: (String) -> URL?` resolver (`FanCard.swift`), and
`IngestionModel.thumbnailURL(forBlobHash:)` is the resolver. Two parallel arrays — a
`[URL?]` beside a `[String]` — were rejected: an index-alignment invariant no
compiler checks is exactly the kind that rots.

### 2.2 §3.1 and §3.4 describe two different piles

- §3.1: "two tilted backing cards … **Exactly the collapsed tile's construction**."
- §3.4: "the pile costs **a handful of cached thumbnails**, bounded by the post's size."

The grid's cards carry no artwork. `fanLayers` is two `CALayer`s filled with
`Theme.NS.selection` and stroked with `hairlineStrong`
(`MasonryGridItem.swift:383, 487`), documented as *"Empty-looking (a tone + hairline,
no artwork): they stand for 'more behind this', not for any particular image."*
§3.4's thumbnail sentence is describing `FanCard`'s Home-overview pile, which is a
different pile doing a different job.

**Settled: §3.1 wins.** The resting pile is two blank tinted cards, matching the
tile. Thumbnails belong to §3.3 and are specified there.

### 2.3 The zoom gate reads the wrong variable

070 §5.2 says gate on `zoom == 1`, "the same gate the drag-out already uses". But
`zoom` is `@State` that only moves at a settle point — the live magnification is
`@GestureState private var pinch` (`ItemDetailView.swift:881`), written by
`MagnifyGesture.updating` and folded into `zoom` only in `.onEnded`
(`:906-907`). `ItemDetailView.swift:190-195` says so in as many words: *"`zoom` (the
@State, not the transient pinch) only changes at a settle point."*

So through every pinch out from fit, `zoom` is still `1`: the pile keeps drawing at
fit geometry while the artwork scales away from it, then vanishes when the fingers
lift. Double-tap-to-reset (`:894-896`) has the mirror problem.

**Settled: gate on the effective scale `zoom * pinch`.** `ZoomableImage` surfaces one
scalar; the rect computation stays outside it (§3.2).

## 3. The design, as settled

### 3.1 `ItemDetailPost`

```swift
/// The post this item belongs to (307/309): its members in post order, the open
/// item's place in them, and a jump. `nil` for an ungrouped item, or a host with
/// no grouping context (the Space board).
struct ItemDetailPost {
    let index: Int                          // 0-based, within the post
    let memberCount: Int
    let blobHashes: [String]                // members in post order
    let thumbnailURL: (String) -> URL?      // resolver, as `FanCard` takes one
    let seed: UUID                          // the representative id
    let jump: (Int) -> Void                 // clamped by the callee, not the caller
}
```

`blobHashes` / `thumbnailURL` are **spread-only** (§2.2) — increments 1 and 2 read
`index`, `memberCount` and `seed` and nothing else.

Assembled by **one pure factory on `PostGroups`**, not per host. The two grid-backed
hosts reach post data differently — `CollectionView` reads `model.postGroups` plus
the cached `model.detailRunIndex(of:)` (`IngestionModel.swift:505`), while
`LibrarySearch` builds its own `PostGroups(items:)` (`LibrarySearch.swift:756`) —
so "plumb it through both hosts" means writing the same derivation twice against
different sources. That is the shape `316` was written to fix ("two lists, one of
them unseen"). `PostGroups` already owns post semantics and is the most heavily
tested type in the area; the factory goes there and each host supplies only its
`jump`.

`SpaceView` keeps passing `nil`. It has no grouping context by design.

### 3.2 The fitted artwork rect

The page measures the **pane** today — `onGeometryChange(for: CGSize.self)` at
`ItemDetailView.swift:195` — and nothing anywhere computes where the fitted image
actually lands inside it. A pile laid against the pane floats detached on the long
axis for any image whose aspect ratio differs from the pane's, which is
[313](../.change-log/313-a-carousel-outlined-in-black.md) reappearing on a new
surface.

**A pure `fitRect(content:in:)`**, computed from `Asset.width` / `Asset.height` —
`Int?`, documented as *"Intrinsic … layout without decoding"*
(`AtelierCore/…/Asset.swift:30-33`) — and the measured pane size. `nil` dimensions
(a media-less kind) means no pile.

Reporting the true drawn rect out of `ZoomableImage` was considered and rejected:
it would add a geometry → `@State` → layout loop to the one view already doing
state-driven geometry work (`reportDisplayTarget`, `:473`), to buy a fraction of a
point that is invisible under a tilted card. The purity argument is the one
`fanPileGeometry` already makes about itself — *"Pure so the 'no card is ever
clipped' invariant is testable across aspect ratios instead of being eyeballed at
one cell size."*

### 3.3 The chip → the sidebar's "Post" row

> **Revised after building it** ([358](../.change-log/358-the-post-position-moves-to-the-sidebar.md)).
> Beside the pager it read as clutter around the only *controls* in the top bar. The
> position now lives in the sidebar's **Source** section as `Image 2 of 4` — Source
> because post grouping is derived from the source, so the row can never be orphaned,
> and because it is the same kind of fact as Platform / Author / Title. The narrow-width
> machinery below (`ViewThatFits`, the measured budget, the `104` reserve) went with the
> chip; a sidebar row has no width contest to lose. The rest of this section stands as
> the reasoning for *why not to reuse `PostBadge`*, which is unchanged.

`⧉ 2 of 4 in this post`, beside the centred pager.

`PostBadge` **cannot be reused**. It is an `@MainActor enum` rendering `NSImage`s
cached by count (`MasonryGridItem.swift:165`), and its own doc says why: *"the
cell's whole reason for existing is that it does NOT host SwiftUI or lay out
subviews per cell (036 §2 A1)."* The top bar is SwiftUI, and the copy is not a bare
count, so the count-keyed cache does not apply.

Generalising `PostBadge` to cache by string was rejected — it breaks the cache's
documented safety argument (bounded distinct counts, never invalidated) and hands
SwiftUI a fixed-scale bitmap that tracks neither `displayScale` nor Dynamic Type.

**Extract the spec, write the second renderer.** One `PostChipStyle` token set —
height, `square.on.square` glyph, h-pad, gap, capsule tone (`Theme.NS.selectionMark`
/ `Theme.Colors` equivalent), contents tone (`mediaBackdrop`), monospaced-digit
weight — read by both `PostBadge.render` and the new SwiftUI chip.

**Narrow widths.** `topBar` is a `ZStack` with a centred pager over a leading /
trailing `HStack` of back-pill, favourite and overflow (`ItemDetailView.swift:252`).
An 18-character chip widens the centred element into the trailing controls. The chip
uses the short form `⧉ 2/4` below a threshold width; nothing overlaps at any width.

### 3.4 The pile

Two blank tilted cards behind the fitted artwork, inset by
`fanPileGeometry(in:maxDegrees:maxInset:minInset:cornerRadius:)`
(`MasonryGridItem.swift:130`) applied to the **fitted rect**, tilted by
`fanRotations(seed:count:maxDegrees:)` (`FanCard.swift:19`) seeded by the post's
representative id.

**On the seed's rationale.** 070 §2 justifies seeding by the representative id as
making the page's pile "geometrically the same pile the user just clicked". That
claim does not hold in general: the grid only fans a **collapsed** post —
`showsFan = postMemberCount > 1 && !postExpanded` (`MasonryGridItem.swift:627`) —
and since 316 made every member reachable, opening from an already-expanded post is
common, and those tiles drew no pile at all.

The pile draws anyway. It says *"this item belongs to a post"*, which is the actual
brief; it is not a promise about the transition. The seed still earns its place
twice over: it is stable across launches (`fanRotations` reads raw uuid bytes, not
`hashValue`, precisely for this), and it does match the tile whenever there was one.
Suppressing the pile for an expanded post was rejected — the page would then say
nothing in exactly the case the grid also said nothing, and it would drag grid view
state across `ItemDetailView`'s presentation-only contract (`:10-15`).

**Three fan implementations, and that is fine.** `FanCard.fanStack` (SwiftUI, square,
hash-backed), `MasonryGridItemCell.layOutFan` (CALayer, aspect, blank), and this one
(SwiftUI, aspect, blank). They differ in rendering layer and sizing model for real
reasons, and under §2.2 this one is two rounded rectangles. What *is* duplicated is
the numeric convention — *count = N+1 because index 0 is the upright front card* —
which currently lives as a comment in both, the cell's reading "matching `FanCard`'s
convention" (`MasonryGridItem.swift:669`). That gets encoded once, as
`fanBackingRotations(seed:cardCount:maxDegrees:)` beside `fanRotations`, returning
just the backing angles so no caller re-derives the off-by-one.

**Visibility** is a pure predicate, not an inline expression:
`showsFanPile(memberCount:effectiveScale:)` and `showsPostChip(memberCount:)`,
mirroring the cell's own `showsFan` / `showsPostChip` (`:627, :635`) in name and
shape.

### 3.5 The spread — optional, and now costed

> **Built** ([360](../.change-log/360-the-pile-opens.md)). One departure from what is
> written below: the trigger is the bottom strip of the fitted artwork, not the pile
> itself. The pile is *behind* the picture and hit-transparent, so hovering it is both a
> mean target and a thing that would fight the drag-out. Everything else — the ~7 cap
> with a spoken `+N`, the per-card bucket, no prefetch — landed as specified.

Hover or click spreads the pile into a shallow arc; click a card to jump. Motion off
`Theme.Motion.gentle`.

- **Cap the arc at ~7 cards with a visible `+N`.** A 15-image rednote carousel
  ([020](./feature-todo/020-capture-rednote.md): 1–15 images) is a layout problem
  before it is a performance one, and a silent cap reads as "covered everything".
- **Cold decodes.** A collapsed post renders only its representative in the grid, so
  the other N−1 members are *not* in `ThumbnailPipeline`'s cache. The spread is
  therefore coldest exactly where the feature is most wanted, and it may fire while
  `DetailSession` still has a full-res native decode in flight from
  `onDisplayTarget`. The cap bounds this.
- **Bucket.** `AsyncThumbnail.bucket` defaults to the 512 ceiling
  (`SharedThumbnail.swift:52`; `thumbnailPixelBuckets = [128, 192, 256, 384, 512]`)
  and the pipeline requires the caller to compute it — *"the cell never guesses its
  own size (036 §4 C3) … merely wasteful, never blurry."* The fan card computes its
  own via `thumbnailPixelBucket(pointLongSide:scale:)`, exactly as `FanCard.tile`
  does. A ~60pt card on a 2× display wants **128**, not 512 — 16× the pixels
  otherwise, per card.

## 4. One fix that is not this feature

`searchDetailRun` is called **inside `body`** (`LibrarySearch.swift:518`), in the
`detail != nil` branch. It runs `searchItems(for:)`, a full `PostGroups(items:)`
(bucket + per-group sort, `PostGrouping.swift:161-184`), `fullRun`, and a
`Dictionary` over every result — O(n log n) across the whole search, on every body
pass while the page is open. The comment at the call site says *"Computed inside this
branch, so a query with no page open pays nothing"*, which is true and accounts only
for the closed case; the page re-evaluates on every ← / →, every zoom settle, and
every geometry tick during a live window resize. Search is the one surface with no
bound on `n`.

The §3.1 factory lives on `PostGroups`, so the naive wiring constructs a **second**
one right beside the first. **Hoist the grouping to `@State`, keyed on
`(results, groupCarousels)`, and hand the one instance to both `fullRun` and the
factory.** This lands with increment 1 because increment 1 is what would double it.

Deliberately *not* optimised: the factory running per body pass in `CollectionView`
(`members(forItem:)` is a dictionary hit plus an array of ≤ ~20 ids), and
`fitRect` / `fanPileGeometry` recomputing per geometry tick. Both are bounded and
cheap — the cell already runs `fanPileGeometry` on every relayout of every visible
cell, and the dictionary-lookup win celebrated at `CollectionView.swift:1249` was
replacing a linear scan of *thousands* of items, not twenty. Revisit only if the
spread ships and profiling disagrees.

## 5. Test plan

070 shipped no test plan. The bar is set by this area already: `DetailStepTests`
opens by quoting the strategy — *"this is where the off-by-one lives … should not be
tested through the view"* — and `fanPileGeometry` is pinned by a parameterized
invariant across five aspect ratios including "the extreme a screenshot produces"
(`MasonryGridItemBadgeTests.swift`). Everything below is pure-function; no view
harness is introduced.

**T1 — `fitRect`, and the composed invariant.** Parameterized over the same aspect
ratios `pileNeverClips` uses, plus degenerate inputs: `nil` dimensions, zero,
negative, `1 × 20000`, a pane smaller than `minInset`. Then the test that actually
matters: for each (image size × pane size), `fanPileGeometry(in: fitRect(…).size)`
still clips no corner. The existing invariant only covers the cell-bounds case, which
is not the rectangle this feature uses.

**T2 — the factory agrees with the run.** For every item in a seeded feed,
`detailPost(forItem:).index` equals that item's position within its post's slice of
`fullRun`. Plus: `nil` for an ungrouped item; `nil` for a would-be single (groups of
one are dropped at `PostGrouping.swift:170`, so `memberCount` is never 1); `seed`
is the representative id; a half-indexed post falls back to feed order per the
all-or-nothing branch (`:171`). T2 is the reason the factory is on `PostGroups` at
all.

**T3 — visibility predicates.** `showsFanPile` across `memberCount` ∈ {0, 1, 2, 15}
× `effectiveScale` ∈ {1, mid-pinch, > 1}, including the mid-pinch case that §2.3
exists to fix. `showsPostChip` likewise.

**T4 — mutation while the page is open.** `⌫` / `⌘⌫` reach the page
(`ItemDetailView.swift:233`), so the user can change the post while looking at it:

1. **A 2-image post loses a member → the group dissolves.** `PostGroups` drops every
   group of one (`:170`), so `memberCount` goes 2 → 0 and both chip and pile must
   vanish, not go stale.
2. **Index shift after a rebuild.** `detailRunIndexByItem` is rebuilt
   (`IngestionModel.swift:559-560`); a `jump` captured before the rebuild targets the
   old indexing.
3. **`jump(i)` out of range** after a concurrent reload — hence "clamped by the
   callee" in §3.1. Writing this test is what forces the clamp to exist.
4. **A media-less member** contributes no blob hash to the spread.

(1) and (4) bite from increment 1. (2) and (3) only bite once the spread exists, but
are written now while the shape is fresh.

## 6. Increments

1. **The factory + the chip + the `LibrarySearch` hoist.** `ItemDetailPost`,
   `PostGroups.detailPost`, `PostChipStyle`, the SwiftUI chip, §4's `@State` hoist.
   Tests T2, T3 (chip half), T4.1, T4.4. Proves the data path and pays off §4.
2. **`fitRect` + the resting pile + the pinch gate.** `fanBackingRotations`,
   `showsFanPile`, the effective-scale scalar out of `ZoomableImage`. Tests T1, T3
   (pile half). The risky half, now with the risk named and bounded.
3. **The spread.** Only if 1–2 leave it wanting — 070 §5.4's judgement stands, and
   §3.5 is what it costs. Tests T4.2, T4.3 come into force here.

## 7. What is still deferred

- **Mixed-kind posts.** Since [310](../.change-log/310-a-tweet-is-its-images.md) a
  tweet fans out into one asset per image, so a post's members can be a mix. Image
  branch first; video / tweet decided after seeing it. T4.4 pins the behaviour in
  the meantime (a media-less member is skipped, not crashed on).
- **Two counters reading as noise.** 070 §5.4's concern is untouched by this review.
  Increments 1–2 ship, and the spread is judged against the result.

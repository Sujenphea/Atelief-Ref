# 356 — The page says which post

## Summary

Increment 1 of [080](../.docs/080-detail-fan-carousel-plan.md): the detail page now says
out loud that the item is part of a carousel, and where inside it you are.

316 made ← / → walk a post as one contiguous run, and stopped there — the page behaved
correctly and communicated nothing. → walked image 1→2→3→4 of a post and then out into the
next tile, and at no point did the page say which of those steps were "inside" the post.
The counter read `12 / 60` throughout. The user clicked a pile and the pile vanished.

Two counters now, deliberately (070 §3.2): the pager is the FEED position, the chip is the
POST position, and neither can express the other's scope.

```
‹  12 / 60  ›   ⧉ 2 of 4 in this post
```

The pile itself is increment 2 and the spread is increment 3; this is the data path plus
the cheap half of the vocabulary.

## What

**`ItemDetailPost`** — the page is presentation-only by contract, so the post arrives as a
value: the open item's index within its post, the member count, the members' blob hashes
and a resolver for the spread, the representative id that seeds the fan, and a jump.
`nil` for an ungrouped item, a host with no grouping context (the Space board), or a
surface with carousel grouping switched off.

**One factory, not two derivations.** `PostGroups.detailPost(forItem:thumbnailURL:jump:)`.
The two grid-backed hosts reach post data by different routes — `CollectionView` reads
`model.postGroups`, `LibrarySearch` builds its own — so "plumb it through both hosts"
would have meant writing the same derivation twice against different sources, which is
exactly the "two lists, one of them unseen" shape 316 was written to fix. It lives on
`PostGroups` because that type already owns post semantics and carries this area's
heaviest test suite, so the one thing that can silently rot — that the chip's index agrees
with the position the arrows actually walk in `fullRun` — is pinned by a unit test rather
than by eye on the page.

The members' blob hashes are recorded by `PostGroups.init` (for grouped items only) rather
than resolved at the call site: the init is already the one pass over the feed that has
the details in hand, and handing the factory the whole `[CollectionItemDetail]` would put
an O(feed) index build inside a view body — the cost §4 below exists to remove. They are
unread until the spread ships; 080 §2.1 is why they are hashes and not `[URL?]`
(`AsyncThumbnail` keys its cache on the hash, so URLs alone re-decode every card).

**`PostChipStyle`.** The `⧉ N` chip is now drawn twice — as a count-keyed `NSImage` in the
grid cell, and live in SwiftUI on the page — so its spec was extracted: height, glyph,
point sizes, padding, gap, capsule and contents tones, semibold monospaced digits. Split
AppKit / SwiftUI exactly as `Theme` splits `Theme.NS` from `Theme.Colors`. `PostBadge`
renders from it; its output and its count-keyed cache are unchanged.

`PostBadge` could not simply be reused, and its own doc says why: *"the cell's whole reason
for existing is that it does NOT host SwiftUI or lay out subviews per cell (036 §2 A1)."*
Generalising its cache to key on strings was rejected too — it breaks that cache's
documented safety argument (bounded distinct counts, never invalidated) and hands SwiftUI
a fixed-scale bitmap tracking neither `displayScale` nor Dynamic Type.

**Narrow widths.** `topBar` is a `ZStack` with a centred pager over a leading/trailing
`HStack`, so an 18-character chip widens the centred element into the trailing star and
overflow menu. The bar's width is measured once and `ViewThatFits` picks the widest form
that survives the remaining budget: `⧉ 2 of 4 in this post` → `⧉ 2/4` → the bare pager,
which is today's layout exactly. The measure is needed because a `ZStack` proposes its full
width to the centred child, so nothing can be inferred from inside it.

**Visibility is a predicate**, `showsPostChip(memberCount:)`, mirroring the cell's own
`showsPostChip` in name and shape rather than being an inline expression.

## §4 — one fix that is not this feature

`searchDetailRun` was called **inside `body`**: a full `PostGroups` (bucket + per-group
sort), `fullRun`, and a `Dictionary` over every hit — O(n log n) across the whole result
set, on every body pass while the page is open. The call site's *"a query with no page open
pays nothing"* was true and accounted only for the closed case; the page re-evaluates on
every ← / →, every zoom settle, and every geometry tick of a live window resize. Search is
the one surface with no bound on `n`.

The new factory lives on `PostGroups`, so the naive wiring would have constructed a
**second** one right beside the first. Instead `SearchDetailContext` carries the run and
the grouping that ordered it as one value, memoized by `SearchDetailContextCache` on
`(resultsVersion, groupCarousels)` — the same memo-box idiom, and the same reason, as
`MoveTargetsCache` (027 · G3). A box rather than a `.task(id:)` or `.onChange` rebuild for
two reasons: it stays LAZY (a query with no page open still pays nothing — the box is only
asked inside the `detail != nil` branch), and it is SYNCHRONOUS, so the page's first frame
has its run instead of opening on an empty pager.

Deliberately not optimised: the factory running per body pass in `CollectionView`. That is
a dictionary hit plus an array of ≤ ~20 ids, where the win celebrated at the neighbouring
`detailRunIndex` call site was replacing a linear scan of thousands.

## Files changed

- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `ItemDetailPost`,
  `showsPostChip(memberCount:)`, the `post` input, `topBarCentre` / `postChip` and the
  bar-width measure
- `AtelierRefs/AtelierRefs/PostGrouping.swift` — `detailPost(forItem:thumbnailURL:jump:)`,
  `blobHashByItem`
- `AtelierRefs/AtelierRefs/MasonryGridItem.swift` — `PostChipStyle`; `PostBadge.render`
  reads it (`PostBadge.height` moves to `PostChipStyle.height`)
- `AtelierRefs/AtelierRefs/CollectionView.swift` — `detailPost(for:)` into the overlay
- `AtelierRefs/AtelierRefs/LibrarySearch.swift` — `SearchDetailContext`,
  `SearchDetailContextCache`, the hoist, the overlay's `post:`
- `AtelierRefs/AtelierRefsTests/DetailPostTests.swift` — new

## Notes

`SpaceView` keeps passing nothing. A board has no grouping context by design, so its call
site is untouched — `post` is defaulted.

Both grid-backed hosts gate the chip on carousel grouping being ON. With it off the run is
raw feed order (`IngestionModel.swift:559`, `SearchDetailContext.init`), so a chip counting
post positions would be describing a walk the arrows do not take.

`jump` is clamped by the CALLEE, per 080 §3.1: a delete or a re-run can shrink the post
while the page is open, and `detailRunIndexByItem` is rebuilt by that same reload — so both
the member and its place in the run are resolved fresh, never captured. Nothing calls it
yet; it exists so increment 3 does not have to retrofit the clamp.

A media-less member (003 · O1 — since 310 a post's members can be a mix of kinds) is
counted, has a position, and is walked onto; it simply contributes no blob hash. So
`blobHashes` is deliberately not index-aligned with `index`: the spread draws cards from
it, it is not a positional map of the post. 080 §7 defers what a mixed-kind post should
*draw*.

Display-only. No schema, no migration, nothing persisted.

Tests: `DetailPostTests` covers 080 §5 · T2 (the factory agrees with the run, for every
item in a seeded feed — plus nil for ungrouped, nil for a would-be single, the
representative as seed, and the all-or-nothing half-indexed fallback), T3's chip half, and
T4.1 / T4.4. All pure functions; no view harness, per `DetailStepTests`' standing strategy.
T1, T3's pile half and T4.2 / T4.3 come with increments 2 and 3.

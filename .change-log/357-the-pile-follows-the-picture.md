# 357 — The pile follows the picture

## Summary

Increment 2 of [080](../.docs/080-detail-fan-carousel-plan.md): the detail page now draws
the grid tile's fanned pile behind the open artwork, so a post looks like a post on the
page and not only in the cell it was opened from.

[356](./356-the-page-says-which-post.md) said it in words (`⧉ 2 of 4 in this post`). This
says it in the shape the user clicked: two blank tilted cards behind the picture, seeded by
the same representative id the tile fanned with, so a given post's pile is the same pile
everywhere and on every launch.

Two blank cards, not thumbnails — 080 §2.2 settled a contradiction in 070 in favour of the
grid's own construction: *"they stand for 'more behind this', not for any particular
image."* Cards WITH artwork are the spread (§3.5), which is increment 3 and still gated.

## What

**`fitRect(contentWidth:contentHeight:in:)`** — where a `.aspectRatio(contentMode: .fit)`
image actually lands inside the media pane. The page measured only the PANE, and nothing
anywhere computed where the picture inside it ends up, so anything laid against the pane
floats detached on the long axis for every image whose aspect ratio is not the window's —
[313](./313-a-carousel-outlined-in-black.md) reappearing on a new surface. Computed from
`Asset.width` / `Asset.height` (*"Intrinsic … layout without decoding"*), so the answer is
known before a byte is decoded and does not change when the 1280 preview swaps for the
full-resolution image. `nil` dimensions are a media-less kind and mean no pile.

Reporting the true drawn rect out of `ZoomableImage` was rejected (080 §3.2): a geometry →
`@State` → layout loop added to the one view already doing state-driven geometry work, to
buy a fraction of a point that is invisible under a tilted card.

**The pinch gate.** 070 §5.2 wanted the pile gated on `zoom == 1`, *"the same gate the
drag-out already uses"*. But `zoom` is `@State` that only moves at a settle point — the live
magnification is `ZoomableImage`'s `@GestureState pinch`, folded in at
`MagnifyGesture.onEnded`. So through every pinch out from fit that gate stays true: the pile
would keep drawing at FIT geometry while the artwork scaled away from underneath it, then
vanish when the fingers lifted. `ZoomableImage` now publishes `zoom × pinch` as ONE scalar
(from `onChange`, never mid-body) and `showsFanPile(memberCount:effectiveScale:)` reads it.
One scalar rather than the pinch alone, because `pinch` is meaningless without the `zoom` it
multiplies and recombining them at the call site is how the wrong variable got read the
first time. Double-tap-to-reset rides the same value — it assigns `zoom`, and `zoom` is half
of the product.

**`fanBackingRotations(seed:cardCount:maxDegrees:)`**, beside `fanRotations`. Every pile in
the app draws its front card upright because the front card IS the artwork, so a caller
wanting N cards behind it asks for `N + 1` angles and starts reading at index 1. That
off-by-one was written out twice — in `FanCard.fanStack` and in `MasonryGridItem.layOutFan`,
whose comment could only say *"matching `FanCard`'s convention"* and hope the next reader
opened the other file. Both call sites now read it from one place; their drawn angles are
unchanged, and a test pins that they are.

**The pile itself** — `DetailFanPile`, the app's third fan implementation and deliberately
so (080 §3.4): SwiftUI like `FanCard`, aspect-sized and artwork-free like the grid cell's,
and neither one's code. `Theme.Colors.selection` fill on a `hairlineStrong` 1pt border,
matching the tile exactly, tilted by `fanPileGeometry` applied to the FITTED rect.

The tile pulls its artwork IN by that inset to make room for the tilt inside a cell that
clips. The page cannot — the artwork is already at fit, and shrinking it would be a visible
lurch on every post you open — so the same inset is spent the other way: the cards are the
fitted rect's own size and their corners swing OUT into `mediaArea`'s `lg` padding. That is
why `maxInset` (12) is kept under `Theme.Spacing.lg` (16), and it is a tested bound, not a
hope.

**Drawn for any grouped item**, including one opened out of an already-expanded post whose
tile drew no pile at all. 070 §2 justified the seed as making this "geometrically the same
pile the user just clicked"; that does not hold in general, since the grid fans only a
COLLAPSED post and 316 made every member reachable. The pile is not a promise about the
transition — it says *"this item belongs to a post"*, which is the brief. Suppressing it
would leave the page silent exactly where the grid was silent too, and would drag grid view
state across `ItemDetailView`'s presentation-only contract.

Image branch only. A media-less kind has no intrinsic size to fit; video's fitted rect
belongs to `AVPlayerView`'s own layout, controls included, and 080 §7 defers it.

## Files changed

- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `fitRect`, `showsFanPile`,
  `DetailFanPileMetrics`, `DetailFanPile`, the `effectiveZoom` state and
  `ZoomableImage.effectiveScale`, `mediaPaneSize` (the pane's whole size now, not just its
  long side)
- `AtelierRefs/AtelierRefs/FanCard.swift` — `fanBackingRotations`; `fanStack` reads it
- `AtelierRefs/AtelierRefs/MasonryGridItem.swift` — `layOutFan` reads it
- `AtelierRefs/AtelierRefsTests/DetailFanPileTests.swift` — new

## Notes

The floor: a `1 × 20000` asset fits to a rect a fraction of a point wide, where two tilted
cards are a smear rather than a pile — and where `fanPileGeometry`'s "never eat more than
half the cell" ceiling starts governing its own answer. Below `minFittedSide` (48pt on the
short side) the page draws no pile at all.

Not optimised, per 080 §4: `fitRect` and `fanPileGeometry` recompute per geometry tick. Both
are a handful of multiplications, and the grid already runs the latter on every relayout of
every visible cell.

Display-only. No schema, no migration, nothing persisted. The pile is hit-transparent — the
artwork's drag-out and the pan gesture own that area.

Tests: `DetailFanPileTests` covers 080 §5 · T1 and T3's pile half, plus the refactor's
behaviour-preservation. T1's real content is the COMPOSED invariant:
`MasonryGridItemBadgeTests.pileNeverClips` pins `fanPileGeometry` against a CELL's bounds,
and the page applies the same function to a different rectangle entirely — the fitted rect,
whose aspect ratio is the image's rather than the layout's. Every (image × pane) pair from
the same five aspect ratios, plus the degenerate inputs (`nil`, zero, negative, `1 × 20000`,
a pane smaller than `minInset`) and the outward-swing budget. T3's mid-pinch case is the one
§2.3 exists for, written as the bug it prevents: `zoom` still reads 1, and the pile is gone
anyway. All pure functions; no view harness, per `DetailStepTests`' standing strategy.

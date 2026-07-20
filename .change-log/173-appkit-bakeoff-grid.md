# 173 — AppKit bake-off grid (037 mode `appKit`, 035 §5 Option B spike)

## Summary

Implements the `appKit` bake-off mode: the read-only `NSCollectionView` spike
that establishes the **ceiling** for 036's 1–2 week grid rewrite. Replaces the
`AppKitBakeoffGrid` placeholder with a real `NSViewRepresentable` over
`NSScrollView` → `NSCollectionView`, a custom `NSCollectionViewLayout` that
wraps the existing `MasonryLayoutCache` verbatim, and layer-backed cells that
never host SwiftUI.

Also turns 036 §2's two load-bearing *assertions* into *measurements*. One of
them needed a correction.

## What was built

- **`MasonryBakeoffLayout`** — `NSCollectionViewLayout`. `prepare()` calls the
  same memoized `MasonryLayoutCache.frames(...)` the production grid calls (no
  masonry math is reimplemented); `layoutAttributesForElements(in:)` is
  `masonryMarqueeIndices` (`MarqueeMath.swift:77`) over the query rect;
  `shouldInvalidateLayout(forBoundsChange:)` compares **width only**. Frames go
  onto attributes with no coordinate conversion.
- **`MasonryBakeoffItem`** — `NSCollectionViewItem` with one layer-backed view:
  `layer.contents` + `.resizeAspectFill` + cornerRadius. No per-cell
  `NSHostingView` (035 §1's original measured bottleneck). Async load with a
  token-based identity re-check; `prepareForReuse` cancels and clears.
- **`BakeoffThumbnailStore`** — byte-costed `CGImage` cache, ImageIO
  downsample to a size bucket, decoded fully off-main
  (`kCGImageSourceShouldCacheImmediately`). Real thumbnails for the real items,
  not placeholder rectangles.
- **`MasonryBakeoffDiagnostics`** — prepare()/invalidation/scroll counters plus
  a rendered-vs-analytic frame comparison, surfaced in a HUD that is hidden for
  the entire duration of any scroll (zero cost on the measured path) and
  repainted on scroll-idle, and printed to the console.
- Read-only by specification: no selection, drag, drop, menu, hover, or GIF.
  `context.wrappers` is ignored, as the seam permits. Scroll target registered
  from `makeNSView` via `NSScrollViewBakeoffTarget`, deferred one runloop turn
  so it does not write harness `@State` during a SwiftUI view update.

## Evidence for 036 §2's two load-bearing claims

Measured on a live `NSCollectionView` in a real window (800×600 viewport, 4
columns, backing scale 2, 40-step scripted scroll), asserted in
`AppKitBakeoffGridTests`.

### Claim 2 — zero layout invalidation while scrolling: **CONFIRMED**

`prepare()` ran **once** (first layout) and **zero times** across the entire
scroll. AppKit asked `shouldInvalidateLayout(forBoundsChange:)` 40 times and
received `false` every time; `layoutAttributesForElements(in:)` was called only
6 times across those 40 steps. No invalidation storm (036 §A-risks).

Recycling confirmed alongside it: **14 live cells for a 2000-item collection.**

### Claim 1 — flipped 1:1 mapping: **CONFIRMED WITH A CORRECTION**

The coordinate *space* claim is right: `NSCollectionView.isFlipped == true`,
the clip view inherits it, and layout **attributes** carry the analytic
`MasonryLayout` frames byte-for-byte (asserted for all 400 items).

But "frames map 1:1 with **ZERO** conversion" is not literally true of the
final **view** frames. AppKit pixel-snaps every item view it places, and
masonry cell heights are `columnWidth / aspect` — routinely fractional — so a
rendered cell lands up to **half a backing pixel** from its analytic frame.
Worst observed: **0.2333pt** against a 0.25pt bound, over 612 cell comparisons,
before and after recycling. A missing flip would have produced errors of
thousands of points, so the space is not in question; the asterisk is
sub-pixel.

Two consequences for Workstream A:

1. **A2/A3 must not assume `cell.view.frame == frames[i]`.** Hit-testing,
   hover, marquee and the selection ring must ride the analytic frames (which
   `MasonryLayout.swift`'s header already mandates), never live cell frames.
   This is a code-review rule, not a bug.
2. The snap rule is **not** `NSView.backingAlignedRect(_:.alignAllEdgesNearest)`
   — 6 of 12 cells disagreed with it — so nothing should try to predict AppKit's
   exact snapping; only the ≤ half-backing-pixel bound is safe to rely on.

## Known confound in the resulting numbers

`layer.contents` requires a `CGImage`, which `ThumbnailCache`
(`NSCache<NSString, NSImage>`) cannot vend, so this mode decodes through its own
ImageIO pipeline — effectively 036 §C1, which the SwiftUI modes do **not** have.
So the **cold** run partly measures Workstream C rather than the framework. The
**warm** run is clean (both sides are a memory-cache hit) and is the number the
framework decision should rest on. Anyone reading 037 §5's decision table
against a cold AppKit number should discount it accordingly, or land C1 first
and re-run.

## Files changed

- `AtelierRefs/AtelierRefs/Debug/AppKitBakeoffGrid.swift` — placeholder replaced
  with the implementation.
- `AtelierRefs/AtelierRefsTests/AppKitBakeoffGridTests.swift` — new; 13 tests
  across 4 suites (frame mapping, width-only invalidation, live
  `NSCollectionView`, thumbnail bucket ladder).

No production grid code was touched: `MasonryLayout.swift`, `MarqueeMath.swift`,
`MasonryLayoutCache.swift`, `CollectionView.swift` and the bake-off harness
files are unmodified.

## Migration notes

None — this is spike code behind the `-grid-bakeoff` launch argument. It deletes
with the `Debug/` bake-off folder.

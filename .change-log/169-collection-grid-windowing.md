# 160 — Collection grid: scroll virtualization (windowing)

## Summary

The collection grid rendered EVERY item's cell eagerly (011-B1 chose eager
`VStack` columns so the cross-axis layout settles in one pass). A Time Profiler
trace of a hard scroll (real data, <200 items) showed ~9.4s of main-thread work
per 20s split between **SwiftUI layout (~7.4s)** — `NSHostingView.layout` →
`ForEachChild.update` → `masonryCell` — and **hit-testing (~2.0s)** —
`NSScrollView.hitTest` → `ContentResponderHelper.containsGlobalPoints` — both
scaling with item count. Thumbnail DECODE was off-main and not a factor.

This lands explicit windowing: only the cells near the viewport are rendered,
each placed ABSOLUTELY at its analytic `MasonryLayout` frame. The analytic frames
already existed (they drive the marquee); windowing re-uses them as the single
geometry source, so render position == frame by construction.

### What changed

- **Windowed render** — the eager `HStack`-of-`VStack`s (`masonryColumns` /
  `columnDetails`) are replaced by `masonryWindow`, a `ForEach` over only the
  visible cells, each `.offset` to its frame origin inside a ZStack whose height
  is set explicitly to the layout's content height (so the scrollbar + marquee
  hit-area still span the whole collection, not the rendered slice).
- **Quantized band** — the scroll offset is quantized to a viewport-height band
  (`gridWindow`); the windowed slice reads the PUBLISHED band, not the live
  offset, and the band is published only when it changes, so a scroll
  re-materializes a few times per screenful, not once per tick. The existing
  non-published marquee viewport write and the new band derivation share ONE
  `onScrollGeometryChange` observer (one guarded publish).
- **One geometry source** — `masonryCell` sizes from its `frame` (the inline
  `columnWidth / aspect` recompute is gone); the marquee reads the same frames.
- **Hover reconciliation** — a windowed unmount can strand `hoveredItemID`
  (SwiftUI may not fire `.onHover(false)` on removal); `hoverAfterWindowChange`
  drops it when the hovered cell leaves the window. The GIF slot is already freed
  by the cell's idempotent `.onDisappear` release.
- **Memoized move targets** — `MoveTargetsCache` computes the move/copy folder
  list once for the drop rail + all cell menus (was recomputed per cell,
  ~326ms/pass).
- **Docs** — the stale `LazyVStack` / `LazyHStack` render contract in
  `MasonryLayout` / `MarqueeMath` now describes the windowed absolute placement.

## Files changed

- `AtelierRefs/GridWindowing.swift` — NEW. Pure: `gridWindow` (band quantizer),
  `masonryVisibleIndices`, `windowedCells`, `hoverAfterWindowChange`.
- `AtelierRefs/CollectionView.swift` — windowed render, band state + guarded
  scroll observer, hover reconcile, `moveTargets` memo; retired `masonryColumns`
  / `columnDetails`; `masonryCell` sizes from its frame.
- `AtelierRefs/CollectionTargets.swift` — NEW `MoveTargetsCache`.
- `AtelierRefs/MasonryLayout.swift`, `AtelierRefs/MarqueeMath.swift` — doc refresh.
- `AtelierRefsTests/GridWindowingTests.swift` — NEW. Quantizer stability/clamp/
  edges; `masonryVisibleIndices` intersection-iff-vs-oracle, full-scroll coverage
  (no cell ever permanently skipped), overscan monotonicity; `windowedCells`
  identity/off-by-one; hover reconciler; GIF-slot idempotency.

## Migration notes

- No API or data changes. The marquee, keyboard nav, reorder, and selection all
  continue to operate over the FULL analytic frames (independent of what's
  rendered), so behavior is unchanged — only which cells are materialized differs.
- Deferred (tracked): thumbnail downsampling + a byte-based cache limit
  (`SharedThumbnail.swift`) for collections over ~512 items — not the <200-item
  bottleneck this addresses. (Complementary to the parallel 012 shared-decode
  work.)

# 181 — AppKit collection grid, read-only behind a flag (036 A1)

## Summary

First real rendering step of the `NSCollectionView` grid migration (036 §2 A1).
Adds a native, layer-backed masonry grid behind the `AtelierUseAppKitGrid` flag
(default **OFF**). With the flag off, the collection grid is **exactly** the
SwiftUI `masonryWindow` path as before — the flag is the safety net. With it on,
the grid renders + scrolls + prefetches through a real `NSCollectionView`, but is
**read-only**: no selection, mouse, hover, keyboard, drag/drop, context menu, or
marquee (those are A2/A3).

Ported from the measured read-only spike (`Debug/AppKitBakeoffGrid.swift`,
validated in 038 §3.4). The spike is **untouched** — it stays byte-identical as a
regression guard; production structure was copied into new files, not moved.

## How it stays smooth / loads correctly

- **Zero layout invalidation on scroll.** `MasonryCollectionLayout.shouldInvalidateLayout(forBoundsChange:)`
  compares **width only**. A scroll moves the bounds *origin*, never the width, so
  the masonry is never re-solved mid-scroll. `layoutAttributesForElements(in:)` is
  `masonryMarqueeIndices` over the query rect (O(cols + hits + logN)); attributes
  are **cached per index** in `prepare()`, so a scroll query only *selects* from
  the cache — it allocates nothing. Width changes are observed off the clip view
  (`frameDidChangeNotification`), not in `updateNSView`.
- **Frames map 1:1** (flipped content space) — the analytic `MasonryLayout` frames
  go onto the attributes with zero conversion. The 038 §3.4 sub-pixel asterisk is
  respected: A2/A3 hover/marquee/selection/hit-testing must ride
  `layout.analyticFrame(at:)`, never `cell.view.frame`.
- **Cells load through `ThumbnailPipeline` with per-cell buckets.** Each cell's
  bucket comes from its **analytic frame** (`gridThumbnailBucket(frame:columnWidth:scale:)`
  → `thumbnailPixelBucket`), not a hardcoded size and not the deleted
  `ThumbnailCache`. Sync cache hit paints with no async hop; otherwise an async
  load with an identity re-check (`loadToken`) on reuse. The coordinator adopts
  `NSCollectionViewPrefetching` → `pipeline.prefetch/cancelPrefetch`; cancel
  excludes the currently-visible index paths so a hash that crossed into the
  visible window is never cancelled out from under the cell awaiting it (036 §4 C1).
- **Data** is `NSCollectionViewDiffableDataSource<Int, UUID>` keyed on membership
  `item.id`. Wholesale republish (load/move/delete/reorder) or collection switch →
  snapshot with `animatingDifferences: false`; same-id content edit →
  reconfigure the live cells in place (re-run `configure`). Collection switch
  resets the scroll offset to top.

## Files changed

Added:
- `AtelierRefs/AtelierRefs/MasonryCollectionLayout.swift` — `NSCollectionViewLayout`
  wrapping `MasonryLayoutCache` verbatim; width-only invalidation; per-index
  attribute cache; `analyticFrame(at:)` for A2/A3.
- `AtelierRefs/AtelierRefs/MasonryGridItem.swift` — `NSCollectionViewItem`,
  layer-backed image path + lazy `NSHostingView` for media-less card kinds; the
  shared pure `gridCellAccessibilityLabel(for:)`; inert A2/A3 seams (below).
- `AtelierRefs/AtelierRefs/MasonryGridHost.swift` — `MasonryGridHost`
  (`NSViewRepresentable`), `GridHostConfiguration` value struct,
  `MasonryNSCollectionView` subclass, the coordinator (diffable data source +
  prefetching), and pure helpers `gridSnapshotIDs` / `gridIDToIndex` /
  `gridApplyStrategy` / `gridThumbnailBucket`.
- `AtelierRefs/AtelierRefsTests/MasonryCollectionLayoutTests.swift` — rect→attrs
  oracle equivalence, attributes carry analytic frames, per-index cache identity,
  width-invalidates / scroll-doesn't.
- `AtelierRefs/AtelierRefsTests/MasonryGridHostTests.swift` — snapshot-diff
  decision, `idToIndex`, bucket-from-frame, accessibility label.

Modified:
- `CollectionView.swift` — `@AppStorage("AtelierUseAppKitGrid")`; `grid` branches
  `isLoaded ? (flag ? appKitGrid : loadedGrid) : skeleton`; new `appKitGrid(geo:)`
  builds the config. Everything outside `grid` untouched.
- `SettingsView.swift` — an **Experimental** section with the flag toggle.

## Inert until A2/A3 (seams built, not wired)

- `CellSelectionState` + `MasonryGridItem.applySelectionState(_:)` — the targeted
  layer-mutation entry point A2 drives from `selectionStore`. Data source only
  ever passes `.inert` in A1.
- `selectionRingLayer` / `cursorRingLayer` (hidden), `circleButton` (hidden,
  disabled) — A2 selection/circle.
- `gifSlot` (nil) — A3 GIF hover overlay.
- `MasonryNSCollectionView` — empty subclass; A2/A3 override
  `mouseDown`/`keyDown`/`menu(for:)`/dragging here.
- `GridHostConfiguration.blobURL` — held for the A3 GIF path; unused in A1.
- In AppKit mode, ⌘±/arrows/keyboard do nothing (toolbar density still works,
  since it lives outside `grid`); that is A2.

## Deviations / honesty

- **`reconfigureItems` is not on `NSCollectionViewDiffableDataSource` in this
  SDK.** The plan named it. Same-id content edits instead re-run `configure` on
  the materialized cells directly (no snapshot, and never `reloadItems` — which
  flashes). Offscreen cells reconfigure through the item provider on the next
  scroll-in. Net effect is the intended in-place reconfigure.
- **Config diffs `(itemsVersion, density)` not `(itemsVersion, columns)`.** The
  plan says "columns"; columns are width-derived, so the density notch is the
  stable user-facing input and the layout derives columns from the live clip
  width (matching the SwiftUI path). Width crossings that change the clamped
  column count are handled by the clip-view width observer.
- **Media-less hosting is slightly wider than "link/tweet only."** The lazy
  `NSHostingView` hosts `AssetContentThumbnail` for *all* media-less kinds
  (colour + unknown too, not just link/tweet cards), reusing the one existing
  render seam. The dominant image/video path is pure layer, as specified.
- **Cannot be verified headlessly:** the `NSViewRepresentable`/coordinator wiring,
  live recycling, prefetch firing, and the pixel-snap bound need a real window —
  covered analytically here by the layout/pure tests (the same oracle the spike's
  live tests assert) and left to manual Instruments verification for the runtime.

## Verification

- Release build: `xcodebuild build -scheme AtelierRefs -configuration Release` →
  exit 0. No new warnings from the added files.
- Tests: `-only-testing:AtelierRefsTests -parallel-testing-enabled NO` →
  **398 tests / 67 suites passed, 0 failures**. Flag-off path keeps every existing
  test green (the SwiftUI grid is unchanged when the flag is off).

## Migration notes

None. Flag defaults off; no data or schema change. Rollback is flipping the flag
(or reverting this commit). A2 builds on `applySelectionState`, `idToIndex`, and
`analyticFrame(at:)`; A3 on `gifSlot` and `blobURL`.

# 077 — Main-window layout fixes (squeezed panes, grid overlap, canvas overlap)

## Summary

Three layout defects found during a whole-app review, the first being the
reported "main page renders its layout incorrectly" bug:

1. **Squeezed/clipped Library panes (the reported bug).** The window minimum
   was 800pt, but the Library tab needs sidebar (min 200) + detail (min 480) +
   inspector (min 260, open by default) = 940pt. Near the minimum, the split
   view broke its constraints and crushed/clipped the panes. The window minimum
   is now **960pt**, so all three panes always fit.

2. **Library grid cells overlapped at narrow column widths.** Thumbnails were
   hard-framed at 128×128 inside `GridItem(.adaptive(minimum: 112, maximum:
   140))`; when SwiftUI packed columns narrower than 128, the fixed cells
   overflowed into their neighbors. Cells are now square and sized by their
   adaptive column (`Color.clear` + `aspectRatio(1)` + fill-overlay), so they
   fit at every window width and stay in agreement with the keyboard-navigation
   column math.

3. **Canvas auto-flow overlapped dragged tiles.** `CanvasContent.layout()`
   flowed un-placed items from (0,0) regardless of explicitly placed tiles, so
   after any drag-to-place (persisted since 050) a rebuild reflowed the gallery
   into the dragged tile's old slot, overlapping it. The justified-rows flow now
   starts **below the bounding box of all placed tiles**. New tests pin the
   behavior (flow-below-placed, and unchanged origin when nothing is placed).

Also in this change:

- **Entitlements:** added `com.apple.security.network.client` — the app is
  sandboxed and `RemoteImageFetcher` performs outbound downloads (paste/drop a
  bare image URL), which the server-only grant would have blocked.
- **Stale docs:** extension README now documents the toolbar popup (bulk
  sweeps) instead of the removed toolbar single-capture; `CanvasContent`'s
  header no longer claims placement persistence is future work.

## Files changed

- `AtelierRefs/AtelierRefs/ContentView.swift` — window `minWidth` 800 → 960.
- `AtelierRefs/AtelierRefs/LibraryView.swift` — `FolderThumbnail` sized by its
  adaptive column instead of a fixed 128×128 frame.
- `AtelierRefs/AtelierRefs/CanvasContent.swift` — auto-flow starts below placed
  tiles; header comment updated.
- `AtelierRefs/AtelierRefs/AtelierRefs.entitlements` — added
  `com.apple.security.network.client`.
- `AtelierRefs/AtelierRefsTests/CanvasPlacementTests.swift` — two new layout
  tests (`flowStartsBelowPlacedTiles`, `flowUnchangedWithoutPlacement`).
- `extension/README.md` — toolbar popup / bulk-sweep section; single-capture is
  right-click only.

## Migration notes

- None for data. The canvas change is presentation-only: persisted placements
  are untouched; only the auto-laid gallery's starting Y moves (below placed
  tiles) on folders where something has been dragged.
- Users with a saved window frame narrower than 960pt will see the window grow
  to the new minimum on next launch.

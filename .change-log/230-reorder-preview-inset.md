# 230 — Reorder preview honours the layout content insets

## Summary

Fix a regression from 226 (whole-panel marquee): starting a manual-sort reorder
drag in a collection made every cell jump — the cells scaled UP horizontally and
shifted up vertically for the duration of the drag, then snapped back on drop.

226 folded the 24pt content margin and the scroll-away header band into the
masonry layout (`contentInsets` + `headerHeight` + `topInset`), so the real
`prepare()` solve packs columns into the inset content width and offsets every
frame down by the full top inset. The reorder preview (`previewFrames`) still
solved edge-to-edge at the raw `topInset` only, so its frames drifted from the
grid the instant a drag began.

The preview now solves at the SAME geometry as the real grid. Added three
accessors on `MasonryCollectionLayout` — `solvedTopInset`, `solvedLeadingInset`,
`solvedTrailingInset` — that expose the exact insets `prepare()` uses, and
threaded `leadingInset` / `trailingInset` through `previewFrames` →
`MasonryLayout.layout`. Preview and solve can no longer disagree.

## Files changed

- `MasonryCollectionLayout.swift` — expose `solvedTopInset` /
  `solvedLeadingInset` / `solvedTrailingInset` (the exact solve geometry).
- `MasonryReorderPreview.swift` — `previewFrames` takes `leadingInset` /
  `trailingInset` (default 0) and forwards them to `MasonryLayout.layout`.
- `MasonryGridHost.swift` — `applyReorderPreview` passes the layout's solved
  insets instead of the raw `topInset`.

## Migration notes

None. The new `previewFrames` parameters default to 0, so search / Home / Spaces
(zero content insets) and the existing `MasonryReorderPreviewTests` call sites
are unchanged.

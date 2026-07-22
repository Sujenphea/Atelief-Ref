# 198 — Floating add 1:1 circle + collapsed-rail alignment

## Summary

Two shell polish fixes:

- **Floating add button** — the circular "+" FAB rendered with sharp top/bottom
  corners (the drop-shadow silhouette was derived from the cell's square bounds,
  not the rounded fill) and could drift off 1:1. It is now AppKit-owned end to
  end: a circular `shadowPath`, a `min(width, height)/2` corner radius, and a
  square `intrinsicContentSize` the button hugs — so SwiftUI hosts it via
  `.fixedSize()` with no competing `.frame`.
- **Collapsed sidebar rail** — the toggle, sort, and trash controls were each
  trailing-aligned, so their differing glyph widths (worst for the sort `Menu`,
  which carries its own chrome) left their centers off one another. They now
  share one centered column, each pinned to a fixed square.

## Files changed

- `FloatingAddButton.swift` — `shadowPath` circle + `min`-side corner radius in
  `layout()`; square-hugging content priorities; `diameter` invalidates the
  intrinsic size.
- `AppShellView.swift` — floating add sized by AppKit (`.fixedSize()`, no `.frame`).
- `SidebarView.swift` — collapsed `rail` uses a centered `railIcon` column; DocC
  links that named the retired `CollectionDropRail` now point at `AssetDragPayload`.

## Migration notes

None. Behavior and layout of the expanded sidebar are unchanged; only the FAB
render and the collapsed rail's icon alignment differ.

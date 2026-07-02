# 043 — Renderer: canvas tile selection + delete affordances

## Summary

The canvas had no selection concept (only double-click-to-play). This adds
single-tile selection with a highlight border and the input plumbing a host needs
to remove/delete the selected tile — the renderer stays app-agnostic (it knows
tiles, not assets or folders).

- **`CanvasEngine`** — `selectedTileID` + `setSelected(_:)` (idempotent). Each
  `sync()` draws a highlight border around the selected tile's on-screen frame,
  or hides it when nothing is selected / the tile is culled off-screen. The
  highlight layer is created lazily on first selection (so an unselected canvas
  keeps its exact sublayer count) and reused. `isSelectionHighlightVisible`
  exposes state for tests.
- **`CanvasHostView`** — single-click selects the tile under the cursor (empty
  space clears); double-click still activates. Right-click shows a *Remove from
  Folder* / *Delete* menu targeting the clicked tile; the ⌫ / Delete (and ⌦)
  keys delete the current selection. New closures `onSelectTile` /
  `onRemoveTile` / `onDeleteTile`, plus a `selectedTileID` passthrough so a host
  can reflect an externally-driven selection into the highlight. The view is now
  a first responder so it receives key events.
- **`CanvasView`** — threads `selectedTileID` + the three new closures through
  `make`/`updateNSView`.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift`
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift`
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasView.swift`
- `CanvasRenderer/Tests/CanvasRendererTests/SelectionTests.swift` (new) — 6 tests:
  no-selection default (lazy layer), select shows highlight, deselect hides,
  off-screen hides / pan-back re-shows, idempotent re-select, single highlight
  when moving the selection.

## Notes

Pre-existing flakiness unrelated to this change: `SpikeDataTests`' "encoded bytes
are deterministic" occasionally differs by a few bytes under the suite's parallel
run (ImageIO JPEG nondeterminism); it passes in isolation. Left as-is.

## Migration notes

Additive — the new `CanvasView` params are defaulted, so existing call sites
(the spike, the app's current `CanvasView(provider:images:onActivateTile:)`) keep
compiling unchanged.

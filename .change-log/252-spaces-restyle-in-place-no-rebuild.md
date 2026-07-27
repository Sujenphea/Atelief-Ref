# 252 — Spaces: in-place restyle (no host rebuild)

## Summary

Fixes three regressions reported after the Phase-2 text work (2A/2C/2B): changing
alignment/colour/font lagged, double-clicking a text tile *usually* failed to
enter editing, and the viewport snapped back to fit after an edit.

Root cause: **every restyle rebuilt the entire canvas.** `updateStyle` →
`performRestyle` → `load()` bumped `contentVersion`, which is bound to
`CanvasView.id(space.contentVersion)`. Any bump tears down the `CanvasHostView`
NSView and builds a fresh one; the new view re-runs `frameToContent()`, resetting
pan/zoom. That single behaviour caused:

- **Restyle lag** — a full DB reload + host teardown/rebuild + re-rasterize on
  every attribute change.
- **Flaky double-click** — `onActivateTile` fires only on `event.clickCount == 2`,
  and `clickCount` only accumulates across clicks on the *same* NSView. A
  write-driven rebuild between clicks (plus the `frameToContent` reframe moving the
  tile) reset the count / moved the target, so the second click missed.
- **Viewport snap-back** — the rebuilt host reframed to fit.

## Fix

Route a restyle through the **in-memory + `renderRevision`** path the drag/arrange
code already uses, instead of `load()`:

- `SpaceContent.setElementStyle(tileID:detail:)` — the style peer of
  `setPlacement`; re-derives one tile's `TileContent` + rect in place on the live
  content instance the renderer already holds.
- `SpaceModel.applyRestyle(_:_:placement:)` — updates `items` + the cached
  `SpaceContent` in memory, bumps `renderRevision` (re-sync in place, no `.id`
  change → no rebuild), then persists with **no reload** (`persistRestyle`,
  replacing the reload-on-restyle `performRestyle`). Both the forward edit and its
  undo/redo route through here, so restyle + undo are flicker-free and keep the
  user's pan/zoom.
- `updateStyle` now bumps `renderRevision` on **every** visible restyle (geometry
  *or* style-only) — it is the redraw signal now that we no longer rebuild to
  redraw. `contentVersion` stays reserved for structural changes (add/remove/
  z-reorder), which legitimately rebuild.

## Follow-up fixes (same session)

Two more issues surfaced from the in-place path and were fixed together:

- **Text snapped back to its pre-move position after an edit.** A drag persists
  with `reload: false`, leaving `items` geometry stale (the live rect lives in
  `SpaceContent.tiles`, read via `livePlacement`). The new `applyRestyle`/
  `updateStyle` were reading geometry from stale `items`, so an edit after a move
  reset the element to its old spot. Both now anchor on `livePlacement` (matching
  the drag/arrange/export paths), and `applyRestyle` de-stales `items` back to the
  live rect. A style-only edit preserves the live position; an auto-size edit grows
  from the moved anchor.
- **Inline editor glyphs were the wrong size at zoom ≠ 1.** The `NSTextView`
  rendered its font at the *world* `fontSize` while the canvas `CATextLayer` draws
  at `fontSize × transform.scale`, so entering edit (or zooming while editing) made
  the text appear to change size. The editor font now tracks the live zoom
  (`nsFont(for:scale:)` + `applyFontScale`, re-applied on every transform change in
  `reposition`).

## Files changed

- `AtelierRefs/AtelierRefs/SpaceContent.swift` — `rows`/`contentByTile` → mutable;
  new `setElementStyle(tileID:detail:)`.
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `performRestyle` → `persistRestyle`
  (no reload); new `applyRestyle` (anchors on `livePlacement`); `updateStyle`
  rewritten to apply in memory + re-sync, reading live geometry; doc comments updated.
- `AtelierRefs/AtelierRefs/InlineTextEditor.swift` — editor font scales with the
  live zoom (`nsFont(for:scale:)`, `applyFontScale`), re-applied on each transform.
- `AtelierRefs/AtelierRefsTests/SpaceTextResizeTests.swift` — the `.fixed`
  style-only test now asserts it bumps `renderRevision` once and does **not** bump
  `contentVersion`; added `restyleDoesNotBumpContentVersion`,
  `restyleAfterMoveKeepsPosition`, and `autosizeAfterMoveKeepsAnchor`. Imports
  `CanvasRenderer` (asserts on live `Tile` positions). File header updated.

## Verification

- `xcodebuild build -scheme AtelierRefs` — BUILD SUCCEEDED.
- `xcodebuild test -only-testing:AtelierRefsTests` — TEST SUCCEEDED (full suite),
  incl. the updated + new restyle regression tests and all `SpaceInlineEditTests`.

## Notes / not included

- Scope was **core rebuild fix only** (confirmed with the user). Deeper zoom-with-
  text smoothing (per-frame `setTextOverlay` dirty-check / gesture-time layer scale
  in `CanvasEngine`) is a **follow-up** — `CATextLayer` still re-rasterizes glyphs
  per `fontSize` step during a pinch. Worth an instrumented pass before optimizing.
- Undo/redo of a restyle is now in-memory (flicker-free) rather than reload-based.
- Structural ops (add/remove/z-order) still reload → rebuild by design.

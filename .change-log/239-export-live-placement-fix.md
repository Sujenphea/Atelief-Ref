# 239 — Export reads live placements (moved tiles kept their old position)

052 · Track B · **B3 fix**. Moodboard export placed some tiles at their
*pre-move* position: any item last moved by a drag or an align/distribute — with
no reload since — exported where it used to be, not where it sits on the canvas.

## Root cause

Three placement stores diverge after a **reload-free** geometry write:

| Store | After a drag / arrange | Read by |
| --- | --- | --- |
| DB | ✅ persisted | the next reload |
| in-memory `SpaceContent.tiles` | ✅ live | the canvas you see |
| `SpaceModel.items` (`[SpaceItemDetail]`) | ❌ **stale** | the export |

`moveTile`→`flushMoves` and `arrange` both move the tile in the live
`SpaceContent` and persist with `reload: false` (deliberately — a reload would
rebuild and flicker). With no `load()`, `items` keeps the old x/y/z until the
next reload. `restack` / `restackSelection` / `arrange` already dodge this via
`livePlacement(_:in:)`; **export** was wired to `space.items` and missed the
seam. So a tile exported correctly only if its last edit was a `reload: true` op
(undo/redo, restack-z, restyle) — otherwise it exported at its pre-move spot.

## Fix

`SpaceModel.placedItems` — the board rows with each row's **live** placement
overlaid from `content()` / `livePlacement` (the same source the canvas draws).
Both export call sites (`MoodboardExportButton`, the File-menu
`ExportMoodboard` focused action) now read `space.placedItems` instead of
`space.items`. WYSIWYG by construction; `.disabled` / item-count checks stay on
`items` (geometry-independent).

## Files changed

- **Modified**: `SpaceModel.swift` (`placedItems` accessor),
  `MoodboardExportControls.swift` + `SpaceView.swift` (both export sites →
  `placedItems`).
- **New**: `AtelierRefsTests/SpacePlacedItemsTests.swift`.

## Tests

- `SpacePlacedItemsTests` (3, over the real temp-`AppServices` harness): a
  reload-free drag leaves `items` stale (x == 0) while `placedItems` carries the
  live x == 500 (the regression, pinned from both sides); after a reload the two
  agree; `placedItems` preserves id / kind / style and item count. Green.

## Migration notes

- No schema or data change — a pure read-path correction. Nothing to re-run.

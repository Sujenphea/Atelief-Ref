# 232 — Spaces canvas multi-select drag (PR 1: click-based)

Adds **multi-selection** to the Spaces board: ⌘/⇧-click to build a selection, drag
any selected tile to move the whole set, and ⌫ / z-order / delete act on the set.
Rubber-band marquee lands in PR 2 (plan `049`). Brings the board toward parity with
the Collection/Search grids.

## Summary

- **Selection is now a set.** The canvas engine owns `selectedTileIDs: Set<Int>`
  (interaction-time, tile-index space); `SpaceModel` mirrors `selectedItemIDs:
  Set<UUID>` (persisted identity). The old single-select `selectedTileID` /
  `selectedItemID` are **derived** conveniences (`count == 1`), never stored.
- **Multi-drag.** Grabbing a selected tile carries the whole selection (Finder
  scope); grabbing an unselected one selects and carries just it. The carried set
  is unioned with the existing frame-as-group members and **de-duplicated**, so a
  selected tile inside a dragged frame moves exactly once.
- **Batched persistence + undo.** A multi-tile drop (and its undo/redo) persists via
  a new `AppServices.setSpaceItemPlacements([...])` in ONE transaction; the burst
  folds into a single "Move Group" undo. Multi-delete and multi-restack (relative
  order preserved) are likewise one batched undo step each.
- **Per-tile highlights.** The engine draws one highlight layer per visible-AND-
  selected tile, managed like `badges`/`textLayers` (outside the layer pool). Layer
  count is bounded by the viewport, not the selection size.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/CanvasSelection.swift` — **new**: pure
  reducer (`selectOnly`/`toggle`/`add`/`marquee`/`clear`, additive ⇧), press
  routing, and the `canvasDragCarry` Finder-scope rule.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` —
  `selectedTileIDs: Set<Int>`, per-tile highlight layers, `beginDrag(alsoCarry:)`
  with de-dup, O(1) tile resolution in the drag-origin paths.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — multi-select
  click routing, deferred click/clear, Delete-on-set, set-based context menu.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasView.swift` — `selectedTileIDs`
  input + `onSelectTiles` / `onRemoveTiles` / `onDeleteTiles` callbacks.
- `AtelierCore/.../Services/AppServices.swift` + `ServiceTypes.swift` — batch
  `setSpaceItemPlacements(_:)` + `SpaceItemPlacement`; single method delegates to it.
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `selectedItemIDs` mirror + derived
  single, reload pruning, batched move/delete/restack (multi), tile↔item mapping.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — canvas callback wiring; action-bar
  z-order now acts on the whole selection.

## Tests

- `CanvasRendererTests/CanvasSelectionTests.swift` — **new** (25): reducer, press
  routing, carry, pruning.
- `CanvasRendererTests/SelectionTests.swift` — +6 multi-highlight invariants (N
  highlights, partial deselect, offscreen, no-leak).
- `CanvasRendererTests/EngineVectorTests.swift` — +4 carry / de-dup (incl. the
  selection ∩ frame-group double-move guard).
- `AtelierRefsTests/SpaceMultiSelectTests.swift` — **new** (7): multi-move/delete/
  restack as one undo, selection pruning + mapping + derived single.
- `AtelierCoreTests/ServicesSpaceTests.swift` — +4 batch write (many, atomic
  rollback, validation, empty).

## Migration notes

- **No schema change.** `setSpaceItemPlacements` is an additive service method over
  existing `space_item` rows; the single `setSpaceItemPlacement` is preserved
  (delegates to the batch).
- `CanvasView`'s selection input/callbacks changed shape (`selectedTileID: Int?` →
  `selectedTileIDs: Set<Int>`; `onSelectTile`/`onDeleteTile`/`onRemoveTile` →
  `…Tiles(Set<Int>)`). The only consumer is `SpaceView`, updated here.

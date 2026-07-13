# 092 — Spaces: undo / redo (005-E3, part 3)

Undo/redo for the space board — create, move (incl. frame group-move), delete,
restyle, and add-from-library. Closes the E3 v1 scope (the doc: "a freeform
editor without undo feels broken"). Scoped to the open space; history resets on
close.

## Summary

- **`AppServices.restoreSpaceItem(_:)`** (Core): re-insert a full `SpaceItem`
  **verbatim** — the inverse of `removeSpaceItem`. Validates discriminator +
  placement; idempotent (a redo that re-inserts an existing id is a no-op). This
  is the primitive that lets create/delete round-trip with the **id preserved**,
  so the undo chain stays stable across cycles.
- **`SpaceModel` undo engine**:
  - A per-space `UndoManager` with `groupsByEvent = false` — each action registers
    its **own closed group**, so `canUndo` is correct immediately and undo is
    deterministic without a running event loop.
  - **All writes funnel through one serial task-chain** (`enqueue`) so an undo can
    never reorder ahead of an in-flight write — the doc's "serialize through the
    model" caveat.
  - `registerReversible` installs a ping-pong (`inverse` on undo, `primary` on
    redo) that re-installs its mirror each time.
  - **Group-move coalescing**: a frame group-drag delivers one `moveTile` per
    carried tile; the burst is buffered and flushed (on the serial queue, after
    the synchronous calls) into a **single** "Move Group" undo.
  - Undoable: add frame / add text / move / delete / restyle / add references.
- **`SpaceView`**: Undo / Redo toolbar buttons (⌘Z / ⌘⇧Z) with action-name help
  and correct enabled state.

## Files changed

- Core: `AppServices.swift` (`restoreSpaceItem`) + `ServicesSpaceTests`
  (verbatim restore + idempotent redo + missing-space `notFound`)
- App: `SpaceModel.swift` (serial queue + undo engine + reversible ops),
  `SpaceView.swift` (Undo/Redo toolbar)
- Added tests: `AtelierRefsTests/SpaceUndoTests.swift` (create↔undo↔redo with
  stable id, delete↔undo verbatim, restyle↔undo, move persists + undo reverts,
  over a real temp `AppServices`)

## Migration notes

None — additive service method + view-model behaviour; no schema change.

## Tests

Core 226 + app 50 green. `restoreSpaceItem` round-trips a removed row with id /
kind / geometry / style intact and is idempotent; the model tests drive the real
async chain (via `waitForWrites()`) and assert each undo/redo settles to the
right board state.

## Known limitations (v1)

- Undo history is per-open-space and resets when you leave the space.
- Not wired into the app's global Edit ▸ Undo menu — the in-space toolbar buttons
  (and ⌘Z / ⌘⇧Z) are the entry points.

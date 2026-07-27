# 260 — Spaces import: SP7 board→board drag-out (canvas as source)

Phase SP7 of the [059 import-into-spaces plan](../.docs/059-spaces-import-plan.md) —
the final surface: drag a reference OUT of an open board onto a sidebar space (or
collection) row, adding a copy there. This completes the Q3 "board→board" decision.

## Framing

Boards open one at a time, so there is no two-board view to drag between — instead a
canvas tile is dragged onto a **sidebar space row**, which already accepts a
membership-less `AssetDragPayload` and calls `addAssetsToSpace` (the shipped sidebar
drop + the SP2 destination). So SP7 is only the SOURCE half: make the canvas emit
that payload.

## Trigger: ⌥-drag (revises the plan's leave-bounds idea)

The plan first proposed starting a drag-out when a tile drag *left the view bounds*.
Implementation showed that's jarring: the tile follows the cursor as an in-view
move, then must **snap back** to origin when the cursor crosses the edge (board→board
is additive — the source stays). **⌥-drag** avoids it: with ⌥ held, a tile drag is a
drag-out session **from the start** — no in-view move, no snap-back — and ⌥ = copy
matches the additive semantics. A plain drag still moves the tile in place.

## Summary

- **`CanvasHostView` is now an `NSDraggingSource`.** An ⌥-drag past the threshold
  starts an `NSDraggingSession` (with a snapshot drag image of the tile) instead of
  the in-view move. Within-app operation is `.copy`; outside the app is refused (no
  file promise). `onBeginTileDragOut(Set<Int>) -> NSPasteboardItem?` is the app seam
  — the package stays payload-agnostic, same layering as the drop seam.
- **Self-drop guard.** While the host owns an active drag-out session
  (`isActiveDragSource`), it refuses drops back onto itself — a board→board copy onto
  the SOURCE board can't duplicate in place.
- **Pure payload mapping (tested).** `SpaceContent.dragOutPayload(forTileIDs:)` maps
  carried tiles → an `AssetDragPayload` (asset ids z-ordered, element/frame tiles
  skipped, `nilSourceID` so the drop copies). `nil` when no asset tiles are carried,
  so ⌥-dragging an element just moves it.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` —
  `onBeginTileDragOut`, ⌥-gated `beginTileDragOut`, drag-image snapshot,
  `NSDraggingSource` conformance, self-drop guard in `dragOperation`.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasView.swift` — seam exposed.
- `AtelierRefs/AtelierRefs/SpaceContent.swift` — `dragOutPayload(forTileIDs:)`.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — `onBeginTileDragOut` wired.
- Tests: `AtelierRefsTests/SpaceLayoutTests.swift` (`SpaceContentTests`) —
  `dragOutPayload` z-order / element-skip / nil cases.

## Migration notes

None. Plain tile drag is unchanged (⌥ gates the new path); the sidebar drop target
already existed. No schema change. Full `AtelierRefsTests` target + 174 package
functional tests green.

## Manual runbook (AppKit session — not unit-tested)

⌥-drag a board tile onto a sidebar space row → it's added to that board, the source
board unchanged. ⌥-drag onto a collection row → added there. Drop back on the same
board → refused (no duplicate). Plain drag → moves the tile in place.

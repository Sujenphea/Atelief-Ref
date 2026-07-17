# 157 — Space tiles: bring-to-front / send-to-back (034 P2)

## Summary

Space tiles had a stacking order (`z`) but no way to change it — a frame or image
stuck behind another couldn't be raised. Added **Bring to Front** / **Send to Back**
for the selected tile.

Surfaced as a toolbar group (with `⌘⇧]` / `⌘⇧[`) rather than a canvas right-click
menu: the canvas is an AppKit `NSViewRepresentable` in the `CanvasRenderer` package,
so a SwiftUI toolbar keeps the change in the app layer and stays discoverable +
keyboard-drivable. The action sets the tile's `z` to one past the current front /
back and persists via the same `setSpaceItemPlacement` write as a move — so it's
**undoable** through the space's own ⌘Z. A tile already alone at the target edge is
a no-op (no z inflation, no undo entry).

## Files changed

### AtelierRefs
- `SpaceModel.swift` — `bringToFront(itemID:)` / `sendToBack(itemID:)` (+ tile-id
  convenience wrappers), `restack(_:toFront:)` with the sole-extreme no-op guard and
  a reversible undo.
- `SpaceView.swift` — a toolbar group acting on `selectedItemID`, disabled with
  nothing selected, `⌘⇧]` / `⌘⇧[` shortcuts.

### AtelierRefsTests
- `SpaceUndoTests.swift` — `restackBringToFront` (raises above all + undo restores)
  and `restackNoOpAtExtreme` (guard leaves z unchanged).

## Migration notes

None. `z` semantics and existing placement writes are unchanged.

## Verify

- Open a space with overlapping tiles → select a back tile → toolbar **Bring to
  Front** (or ⌘⇧]) → it draws over the others → ⌘Z restores its order.
- **Send to Back** (⌘⇧[) pushes the selected tile behind the rest. Both buttons are
  disabled when no tile is selected.

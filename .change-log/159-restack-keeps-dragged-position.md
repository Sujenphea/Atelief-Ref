# 159 — Space z-order: restack keeps the dragged position

## Summary

Bring-to-Front / Send-to-Back snapped a tile back to its pre-drag position: after
moving a tile it would jump to where it used to be while only its z changed.

**Cause.** A drag (`moveTile`) is flicker-free: it updates the live position in
`content.tiles` and persists with `reload: false`, so `self.items` keeps the
*stale* pre-drag x/y. `restack` read x/y/w/h from `items` and wrote them back
alongside the new z — clobbering the moved position with the old one, then
reloaded, reverting the drag.

**Fix.** `restack` now reads the *live* placement from `content()` (which reflects
the in-place drag) via a new `livePlacement(_:in:)` helper, falling back to the
stored row when the tile isn't on the board. z is never touched by a drag, so the
front/back extreme is still computed from `items`.

## Files changed

### AtelierRefs
- `SpaceModel.swift` — `restack` reads x/y/w/h from the live content tile, not the
  stale `items` row; new `livePlacement(_:in:)` helper.

### AtelierRefsTests
- `SpaceUndoTests.swift` — `restackKeepsDraggedPosition`: drag a tile without a
  reload, then bring-to-front, and assert the moved x/y survive.

## Migration notes

None.

## Verify

- On a space, drag a tile somewhere, then Bring-to-Front (⌘⇧]) or Send-to-Back
  (⌘⇧[): it changes stacking order and stays where you dragged it.

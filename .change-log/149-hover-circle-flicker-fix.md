# 149 — Grid: hover selection circle flicker / wrong-target fix

## Summary

Fixes a regression where hover-clicking a cell's selection circle **opened the
item (or single-selected it)** instead of entering multi-select mode — the circle
visibly **flickered** as you reached for it.

Root cause was a hover-steal, not the circle markup (that's unchanged since 144).
The circle is a ZStack sibling rendered ON TOP of the cell, but its visibility was
keyed off `CollectionCell`'s own `.onHover`. Moving the pointer onto the circle to
click it occludes the cell, so the cell's hover fired **false** → `hoveredItemID`
cleared → circle hid → pointer was over the cell again → hover true → circle
reappeared. During that oscillation the click fell through to the image button
underneath, which in idle mode routes `.tapImage` (open / single-select) rather
than the circle's `.tapCircle` (toggle multi-select).

Fix: drive circle visibility from the **ZStack container's** `.onHover`, which
encloses both the cell and the circle — so travelling onto the circle still counts
as hovering the cell. The circle stays put, and the click lands on it. The cell's
internal `.onHover` now serves GIF-dwell only (`onHoverChanged` is a no-op).

## Files changed

### AtelierRefs
- `CollectionView.swift` — `masonryCell`: `.onHover` moved from the child cell to
  the ZStack container; `CollectionCell(onHoverChanged:)` closure now a no-op.

## Migration notes

None. GIF hover-dwell animation is unaffected (still local to `CollectionCell`).

## Verify

- Grid → hover a cell → the circle appears and **stays** (no flicker) as you move
  onto it → click it → the cell enters selection mode (checkmark), circles appear
  on all cells → click more circles to accumulate a multi-selection.

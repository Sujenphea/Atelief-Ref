# 144 — Selection circle: lift out of the cell's `.draggable` (hover-click fix)

Fixes the bug where **hover-clicking a grid cell's selection circle did nothing** —
the pointer-only affordance that enters multi-select mode. The circle is small
(~20pt) and sat *inside* the cell's `.draggable` surface, so a press on it raced —
and lost to — the drag gesture: the toggle was never delivered.

## Root cause

Every grid cell is `.draggable` (`CollectionView.masonryCell`). The circle was a
nested `Button` in `CollectionCell`'s `.overlay`, firing through
`PressReportingButtonStyle` on the `isPressed` edge. On such a tiny target the
slightest pointer drift routes the press into the cell's drag gesture before
`isPressed` is ever observed — no mouse-up "click" fires, so the toggle is dropped.
The large image target rarely trips this; the corner circle trips it constantly.

## Fix (chosen in review: "lift out of draggable")

Render the circle as a ZStack **sibling above the cell, outside the `.draggable`**,
so a plain `Button` receives the click cleanly — no drag race.

**`CollectionCell.swift`**
- Removed the circle `Button`, its `circlePressConsumed` state, the `showsCircle`
  computed, the circle overlay + fade `.animation`, and the local `isHovering`
  state (it only fed `showsCircle`).
- Replaced `onCircleToggle` with `onHoverChanged(_:)` — the cell now reports hover
  crossings up so the parent can decide circle visibility. GIF-dwell hover stays
  local (still driven off the same `.onHover`).
- `PressReportingButtonStyle` stays — the image button still needs the down-edge
  path to beat the drag.

**`CollectionView.swift`**
- New `@State hoveredItemID: UUID?`, set from the cell's `onHoverChanged`.
- `masonryCell` now wraps the cell in a `ZStack(alignment: .topTrailing)`; the
  circle sibling shows when `selection.isSelecting || hoveredItemID == id` and
  fades via `.transition(.opacity)` + a scoped `.animation(value: showsCircle)`.
- New `selectionCircle(for:)` — a plain `.buttonStyle(.plain)` `Button` calling
  `.tapCircle`, `.accessibilityHidden(true)` (the cell already announces + toggles
  selection, so this avoids double-exposing it to VoiceOver — parity with the
  pre-lift children-ignored cell).

## Tradeoff accepted

Hover state is hoisted to `CollectionView`, so a hover crossing now re-evaluates the
grid body. Cells are `.equatable()` and their inputs don't include hover, so they
skip re-render — only the circle sibling appears/disappears. Crossings fire per
cell boundary (not per pixel), so the cost is negligible.

## Verification

- `xcodebuild build` (AtelierRefs) — **BUILD SUCCEEDED**.
- `xcodebuild test -only-testing:AtelierRefsTests` — **TEST SUCCEEDED**.
- Interactive hover→click is not headlessly testable — please confirm in the app:
  hover an idle cell, click the circle → it should enter selection (no dropped
  click), and drag-to-move on the rest of the cell should still work.

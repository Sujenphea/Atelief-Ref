# 275 — Tidy Up, and an exact gap

## Summary

`CanvasArrange` could align and distribute, but distribution *equalises* the gaps it
finds while holding the bounding box fixed — so neither "clean this up" nor "put exactly
24 between these" was expressible. Both now are.

- **Tidy Up** — one op in the multi-selection bar: snap a messy selection into clean
  rows at a uniform gap.
- **Gap** — a popover taking an exact number, applied across or down.

## Tidy Up: one algorithm, no mode to infer wrongly

Row, column and grid are the same thing — cluster the rects into rows by vertical
overlap, then lay each row out left-to-right. One cluster is a row; one item per cluster
is a column; anything else is a grid.

**Idempotence was the design constraint**, not a bonus: `CanvasArrangeTests` asserts it
over `allCases`, and clicking Tidy Up twice must not creep. Every rule survives its own
output — anchor on the top-left (which doesn't move), cluster on *strict* overlap (so
rows a gap apart, even a zero gap, re-cluster identically), and take the **smallest**
observed gap (so re-deriving it afterwards returns the same number). That last rule also
never makes a layout bigger than the one the user built. A fully-overlapping selection
falls back to a default gap rather than collapsing onto a point.

## The exact gap: the enum stays closed

`Operation` is `CaseIterable` and the bar renders it with `ForEach(allCases)`; a case
with an associated value cannot be `CaseIterable`, so adding one would break the wiring
for all eight existing ops. The gap gets its own entry point over the same kernel
instead. `arrange` and `pack` share `applySelectionLayout`, extracted from `arrange`'s
tail, so the no-op filter, in-memory mirror, `renderRevision` bump and `reload: false`
exist once.

## The control is a popover, and that is correctness

**A focusable field in the action bar would have been a bug.** That bar floats over the
canvas, and a focused field there swallows ⌫ and the V/F/T tool keys — the shape of both
269 and 271. A popover is what the app already uses for focus-taking controls, because it
is expected to hold focus and gives it back. First responder is returned to the canvas
host explicitly on dismiss, deferred off the view update.

## Files changed

- `AtelierRefs/AtelierRefs/CanvasArrange.swift` — `.tidyUp`, `pack`, `Axis` internal
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `applySelectionLayout`, `pack`
- new: `AtelierRefs/AtelierRefs/SpaceGapPopover.swift`
- `AtelierRefs/AtelierRefs/SpaceView.swift` — the Gap button, the Tidy Up symbol
- new tests: `CanvasTidyPackTests` (14)

## Migration notes

None. Both ops move x/y only and persist through the existing shared placement path, so
undo/redo and the camera behave exactly as for the other eight.

## Tests

829 app tests, 370 renderer tests. Adding `.tidyUp` to `Operation` also enrolled it in
`CanvasArrangeTests`'s `allCases` invariants for free. Full write-up in
`.docs/066-spaces-gap-arrange-plan.md`.

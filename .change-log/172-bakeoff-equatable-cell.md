# 172 — Bake-off mode `swiftUIEquatable` (035 §5 Option A)

## Summary

Implements the third bake-off grid (037): the current windowed SwiftUI grid with
the per-cell tree hoisted into an `Equatable` view, so SwiftUI's diff can skip
`body` for cells that did not change at a band crossing.

035 §4 measured the post-windowing residual as `masonryCell` (763ms) +
`ForEachChild.updateValue` (842ms) per 20s — a band republish re-evaluates every
windowed cell (~100) when only ~8–12 actually entered or left the window. Option
A collapses that by making the cell comparable.

`SwiftUIEquatableBakeoffGrid` is a deliberate near-copy of
`SwiftUIWindowedBakeoffGrid`: same layout cache, same band quantization, same
windowing filter, same cell content, same wrapper chain, same scroll-target
registration. The ONLY difference is `MasonryCellView` + `.equatable()`. Two
files differing in one construct is what isolates the variable; a shared helper
parameterised by "equatable or not" would put a branch in both hot paths and
neither number would be clean.

## What `==` compares, and why

Every stored property of `MasonryCellView` is a value that affects what is drawn,
and every one is in `==`: `detail.item.id`, `detail.asset`, `frame`, `url`,
`gifURL`, `isSelected`, `isCursor`, `isSelecting`, `showsCircle`, `moveTargets`,
`wrappers`. No closure is stored — the press/click/hover handlers, the drag
payload, the drop handler and the menu content are all built inside `body`. A
stored closure cannot be compared, so it would force an exclusion, and an
excluded input is one that can go stale unnoticed.

The single non-compared property is `hover: BakeoffHoverSink`, a class the grid
owns for its lifetime and whose closure it refreshes in place. It is a constant
across any two comparable cells, not an omission — the same discipline
`SwiftUIScrollPositionTarget.scrollTo` already uses.

## Files changed

- `AtelierRefs/AtelierRefs/Debug/SwiftUIEquatableBakeoffGrid.swift` — replaced the
  placeholder with the mode: the grid, `MasonryCellView`, `BakeoffHoverSink`.
  `BakeoffModePlaceholder` is retained here (`AppKitBakeoffGrid` still renders it).
- `AtelierRefs/AtelierRefsTests/MasonryCellEquatableTests.swift` — new. One test
  per appearance-affecting input, each changed ALONE, asserting `==` is false
  (the omitted-field guard 035 §5 names as the whole risk), plus both directions
  of the equal case.

## Migration notes

None. Debug/bake-off surface only; no production view, model or schema is
touched. `GridBakeoffMode.swiftUIEquatable` now runs instead of refusing.

Measure in RELEASE (037 §3.1) — Debug body-evaluation costs would damn SwiftUI
unfairly, which is the single most likely route to a wrong 1–2 week decision.

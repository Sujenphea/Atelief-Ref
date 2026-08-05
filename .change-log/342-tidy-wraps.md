# 342 — Tidy Up Wraps

[076] T1. On a space with many tiles, Tidy Up collapsed everything into one
enormous row — 60 tiles came out as a single row thousands of points wide,
off-screen at any usable zoom. Two independent structural causes in
`CanvasArrange`, both now fixed.

## Cause 1 — the row clustering chained transitively

`tidyRows` grew the open row's bottom edge with `max(openBottom, rect.maxY)`.
That bottom only ever moves DOWN, and it moves down with each member's
*position*, so membership was transitive overlap rather than overlap with the
row: A overlaps B, B overlaps C, C overlaps D, and A and D land in one row
sharing no vertical extent at all. A staircase chains end to end — and a bulk
drop, which leaves tiles at slightly different y, is exactly that chain.

The open row now has a **band**: anchored at the row's top, reaching down by the
tallest member's height. The band cannot reach past `rowTop + tallestHeight`
however many members join, so the chain is bounded by construction rather than
in practice. Taking the tallest member's height rather than only the first
member's extent is the one concession — it keeps a ragged row of mixed heights
reading as one row. The row's median was the other candidate and was rejected:
the median moves as members are added, so a shallow staircase still creeps in
one tile at a time.

This is the change that makes the many-item case produce rows at all, before
wrapping even applies.

## Cause 2 — there was no width bound anywhere

A row was laid out left-to-right until its members ran out. `tidy` now carries a
`maxWidth` and starts a new row when placing an item would push the row past it.

**The bound comes from the rects' total area, not from the selection's box:**
`sqrt(totalArea × 16:9)`, quantised down to 100pt, floored at 1600. The box is
the obvious source and the wrong one — it NARROWS the moment a wrap happens, so
a box-derived bound comes back smaller on the next pass and the layout creeps
narrower on every press. Total area is invariant under tidy (sizes are
preserved, and the array order with them, so the sum is bit-identical), which
makes idempotence structural rather than something to hope for. The target
aspect is a fixed 16:9, not the viewport's, so the same selection tidies the
same way in a resized window.

1600 is `SpaceLayout.maxRowWidth`, mirrored rather than referenced so the kernel
stays a `[CGRect] → [CGRect]` island with no dependency on the space layer (a
test asserts the copy has not drifted). It is **borrowed, not derived**:
`SpaceLayout` chose it for flowing 240-high rows on bulk add, and as a bound for
tidy it is arbitrary. It is a FLOOR, not only a degenerate-case guard — below it
the derived bound would wrap selections tidy already handles correctly (three
tiles in a row, a 2×2 grid), because `sqrt(area × 16:9)` for a handful of tiles
is narrower than the row they form. Flooring confines the wrap to the many-item
case, which is where the bug lives, and covers a zero-area selection with no
division and no square root of zero.

A row always accepts its first item, however wide. A selection mixing a huge
frame with small tiles has items wider than the bound on their own, and a row
that could refuse every item is a loop that never terminates. Such an item lands
alone on its row and overhangs.

## What did NOT change

- **Tile sizes are preserved.** Every output rect's `size` equals its input's —
  this is wrapped rows, not a uniform grid. A true uniform grid forces every tile
  to one cell size and is a different verb; [076] T3 leaves it optional and out
  of scope.
- The anchor (the selection's top-left), the strict-overlap rule that keeps a
  `gap == 0` tidy stable, and the gap derivation (`tidyGap` — smallest observed,
  falling back to `defaultTidyGap` = 20) are untouched. Wrapped rows are spaced by
  the same derived gap as clustered ones.
- Three tiles roughly in a row still snap to a row; a column still snaps to a
  column; a 2×2 grid stays 2×2. Every pre-existing tidy test passes unchanged.
- Undo is still one entry ("Tidy Up"). `SpaceModel.applySelectionLayout` builds
  its edit list from every selected item whose placement changed, so a wrapped
  tidy that moves more tiles produces a longer list inside the same single undo
  step, never a pre-wrap subset.

## Files changed

- `AtelierRefs/AtelierRefs/CanvasArrange.swift` — band-based row clustering in
  `tidyRows`; the wrap in `tidy`; new `tidyMaxRowWidth(_:)`, `tidyTargetAspect`,
  `tidyBoundQuantum`, `fallbackMaxRowWidth`.
- `AtelierRefs/AtelierRefsTests/CanvasTidyPackTests.swift` — nine tests: the wrap
  at N=60, wrapped rows use the derived gap, the staircase does not chain,
  idempotence over five passes at N=60, sizes preserved at N=60, the degenerate
  pile, zero-area rects, the mirrored-constant drift guard, an item wider than
  the bound.
- `AtelierRefs/AtelierRefsTests/CanvasArrangeTests.swift` — the `allCases`
  invariants (count/size preserved, idempotent) now run over a 60-tile scatter as
  well as the 4-rect spread. At N=4 a row re-clusters into a row and the
  idempotence assertion passes whether the bound creeps or not; N=60 is where
  creep is visible.

## Verification

`xcodebuild build` succeeded. Full suite: 1399 passing, 0 failing. Mutation
check: reverting the band fix fails `staircaseDoesNotChain` and nothing else;
disabling the wrap fails `manyTilesWrap`, `degeneratePileFallsBackToMaxRowWidth`
and `oversizeItemStillPlaced`.

## Migration notes

None.

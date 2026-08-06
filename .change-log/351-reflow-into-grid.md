# 351 — Reflow Into Grid

A tenth arrange op, sitting in the spacing popover under Tidy Up. **Tidy cleans up
what you built; Reflow repacks it like a fresh bulk add.** Tidy preserves your
arrangement — sizes untouched, your clusters kept, your own smallest gap re-used —
which is exactly why it can never hand you rows that line up along their bottom
edge. Reflow throws the arrangement away and keeps only the **reading order**: the
shape goes, the sequence stays. Every tile is normalised to one row height, its
aspect intact, and flowed left-to-right into justified rows.

Tidy is untouched. `tidy`, `tidyRows`, `tidyGap` and `tidyMaxRowWidth` behave
exactly as they did; a test pins tidy's size preservation next to its new sibling,
because the one way this change could have gone wrong invisibly was by teaching
tidy to resize too.

## The two decisions

**The row height is a fixed 240, not derived from the selection.** The obvious
derivation — the selection's median or mean height — is the wrong one for the same
reason a box-derived wrap bound was wrong for tidy [342]: it changes under its own
output. Pass one normalises every height, so pass two measures a different median,
and the block creeps on every press. A fixed height is stable by construction. It
also buys the thing the verb actually claims: 240 is `SpaceLayout.rowHeight`, the
height a bulk add flows tiles in at, so a reflowed block and a freshly-added one
are the same size. Same reasoning for the gap — a fixed 16 (`SpaceLayout.spacing`)
rather than `tidyGap`'s smallest-observed, because once every tile is a different
size from the one the user placed, the gaps they left describe a layout that no
longer exists.

**The wrap bound is derived from the RESIZED rects, not the input.** This is the
correctness crux and it is one line. `tidyMaxRowWidth` reads *total area*, and the
resize changes total area — a 100×50 tile becomes 480×240. Hand it the originals
and pass two, whose input *is* the resized set, sees a different area, gets a
different bound, and lays out a different number of rows. The mutation is worth
naming because it looks harmless: `tidyMaxRowWidth(rects)` instead of
`tidyMaxRowWidth(sized)` fails `reflowIsStableUnderItsOwnOutput` and nothing else.

Idempotence then falls out in three steps, and the doc comment spells them out:
after one pass every tile is exactly 240 high, so the resize on pass two is the
identity (a tile's aspect is now `width / 240`, and `240 × that` is the width it
already has); total area is therefore unchanged, so the bound is unchanged; and
`tidyRows` over the output re-clusters exactly the rows just laid out, because a
row's members share a top edge, the band is 240 tall, and the next row starts at
`+ 240 + 16` — strictly outside it. Same order, same bound, same output.

Everything else is borrowed from tidy deliberately: the anchor is the input
selection's bounding-box top-left, so the block repacks where it already sits
rather than jumping across the canvas; and the wrap never fires on an empty row,
so a tile wider than the bound (a panorama) lands alone and overhangs, because a
row that can refuse every item is a loop that never ends.

240 and 16 are **mirrored** into `CanvasArrange`, not read from `SpaceLayout`,
following `fallbackMaxRowWidth`'s precedent — the kernel stays the
`[CGRect] → [CGRect]` island its header describes. The existing drift test grew
from one constant to three.

## What the spec got wrong: the apply path dropped the size

`SpaceModel.applySelectionLayout` — the shared body behind both `arrange` and
`pack` — built its `Placement` as `w: entry.p.w, h: entry.p.h`, carrying the sizes
from the *live* placement and discarding whatever the kernel returned. It also
called the two-argument `content.setPlacement(tileID:x:y:)`. That was correct for
every op that existed: `apply`'s doc comment promised "sizes are preserved, only
the relevant origin coordinate moves", and nine ops kept the promise, so the
computed size was thrown away with nothing to notice.

Reflow is the first op for which it is false. Left alone, Reflow would have moved
tiles into a grid at the sizes they already had — rows overlapping or gaping, and
no visible resize at all. The rect now round-trips whole, origin **and** size, and
the in-memory mirror uses the four-argument `setPlacement` the resize-handle drag
already had.

Undo needed nothing beyond that, and it is worth saying why: `applyPlacementEdit`
captures `old` as the full pre-op `Placement` and its inverse persists it through
the same path with `reload: true`. Because `old` already carried w/h, one ⌘Z
restores the sizes the moment `new` carries them too. There is a test that says so,
and reverting the `new` half fails it and nothing else.

`apply`'s doc comment now names `.reflowGrid` as the exception and tells callers
they must carry the size through.

## The invariant that had to be narrowed

`CanvasArrangeTests.preservesCountAndSize` runs over `Operation.allCases` and
asserted count *and* size for every op. `.reflowGrid` is excluded by name, with a
comment saying why — the count half still runs for it, and what reflow does
preserve (count, and each tile's aspect) is asserted in `CanvasTidyPackTests`. The
invariant was **not** weakened for the other nine: "an op moves an origin and
nothing else" is still true of them and still worth holding them to. The other
three `allCases` invariants — idempotence, no-op below the minimum, and the
`minimumCount` / `isDistribute` split — hold for reflow unchanged, so they pick up
the new case for free. So does `SpaceBarModeTests.groupsPartitionEveryOp`, which
required the new op to land in exactly one group.

## Files changed

- `AtelierRefs/AtelierRefs/CanvasArrange.swift` — the `.reflowGrid` case,
  `reflowGrid(_:)`, and the mirrored `gridRowHeight` / `gridSpacing`.
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `applySelectionLayout` writes the
  whole rect (size included) and mirrors it into the live content with
  `setPlacement(tileID:x:y:w:h:)`.
- `AtelierRefs/AtelierRefs/SpaceArrangeGroups.swift` — `.reflowGrid` joins the
  `.spacing` group; `rectangle.grid.2x2` as its glyph (a grid of *rectangles*
  against tidy's squares — the uneven cells are the distinction); the group tooltip
  names the fourth op.
- `AtelierRefs/AtelierRefs/SpaceSpacingPopover.swift` — a "Reflow" section below
  "Tidy up", its own section rather than a second button under tidy's heading,
  because the two are different acts and not two strengths of one verb. The help
  string names the resize, since that is the surprising half.
- `AtelierRefs/AtelierRefsTests/CanvasTidyPackTests.swift` — a `Reflow into grid`
  section: uniform height with aspect kept, idempotence over five passes on four
  fixtures, the wrap measured against the post-resize bound, rows justified on both
  edges, reading order preserved through a wrap, the anchor, no tile lost, a
  degenerate rect, the no-op floor, and tidy's size preservation re-pinned. The
  drift test now covers all three mirrored constants.
- `AtelierRefs/AtelierRefsTests/CanvasArrangeTests.swift` — the size half of the
  `allCases` invariant excludes `.reflowGrid`.
- `AtelierRefs/AtelierRefsTests/SpaceArrangeTests.swift` — the model contract: sizes
  reach the store and one ⌘Z restores the old ones; a second reflow writes nothing
  and adds no undo entry.

## Verification

Full app suite: **1532 → 1549 passed, 0 failed** (`xcodebuild test -scheme
AtelierRefs -destination 'platform=macOS'`). `swift test` in `CanvasRenderer/`: 418
tests in 50 suites, unchanged and passing — nothing in that package was touched.

Two mutation checks, both run:

- `tidyMaxRowWidth(sized)` → `tidyMaxRowWidth(rects)` fails
  `reflowIsStableUnderItsOwnOutput` and only it.
- `applySelectionLayout`'s `w: Double(r.width), h: Double(r.height)` reverted to
  `w: entry.p.w, h: entry.p.h` fails `reflowRoundTripsSizes` and only it.

The popover row and the group glyph are view code, so they are compile-only plus
manual. Worth a human pass: that `rectangle.grid.2x2` renders on macOS 26 and reads
as distinct from tidy's `square.grid.2x2` at 15pt; that the four-op spacing panel
is not too tall now; and a reflow on a board mixing images with **text** boxes (see
below).

## Migration notes

No schema change — reflow writes through `setSpaceItemPlacements`, the same path a
drag and a resize already use.

Two behaviour changes worth knowing:

- **`SpaceModel.applySelectionLayout` now persists `w`/`h` for every op that goes
  through it**, not just reflow. For the nine existing ops this is a no-op by
  construction (the kernel hands back the size it was given, so `new == old` on
  those fields and the no-op filter still drops unchanged edits). But any *future*
  transform passed to it — `arrange`, `pack`, or a new caller — will now have its
  sizes honoured rather than silently ignored, which is the right default and the
  opposite of what the method used to do.
- **Reflow resizes text elements too**, because the kernel is identity-agnostic and
  sees only rects. A hugging or auto-width text box reflowed to 240 high keeps its
  stored geometry until the next restyle or resize re-derives it — the derivation
  in `autosizedFrame` is not re-run by the arrange path. In practice a mixed
  selection is unusual and ⌘Z is one keystroke away, so this is recorded rather
  than special-cased; if it becomes a complaint, the fix is to exclude auto-sized
  elements from the resize half rather than from the op.

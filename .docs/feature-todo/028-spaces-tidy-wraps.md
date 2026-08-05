# 028 — Tidy Up Degenerates Into One Enormous Row

> "Tidy function for large number of items condense into one row instead of a
> uniform grid." Correct, and it is not a tuning problem — `tidy` has **no width
> bound at all**, and its row-clustering rule chains transitively, so a dense
> scatter reliably collapses to a single row N items wide.

## Current state (verified)

`CanvasArrange.tidy` (`CanvasArrange.swift:121-146`) does three things: cluster
into rows, derive a gap, lay each row out left-to-right from the selection's
top-left. There is **no wrap condition anywhere** — a row is laid out until its
members run out:

```swift
for row in rows {
    var x = box.minX
    for index in row {
        result[index] = CGRect(x: x, y: y, …)
        x += size.width + gap          // ← nothing ever resets x mid-row
    }
    y += rowHeight + gap
}
```

So the row count is decided entirely by `tidyRows` (`:148-174`):

```swift
var openBottom: CGFloat = 0
for index in topDown {
    if !rows.isEmpty, rects[index].minY < openBottom {
        rows[rows.count - 1].append(index)
        openBottom = max(openBottom, rects[index].maxY)   // ← grows, never shrinks
    } else {
        rows.append([index]); openBottom = rects[index].maxY
    }
}
```

`openBottom` is monotonically non-decreasing **within a row**, so membership is
*transitive overlap*, not overlap with the row: A overlaps B, B overlaps C,
C overlaps D — and A, B, C, D are one row even if A and D share no vertical
extent whatsoever. A staircase of tiles chains end to end. A pile of images
dropped at slightly different y positions — which is what a real board looks like
after a bulk drop — is exactly that chain.

Result: 60 tiles → one row ~60 × 400pt ≈ 24,000pt wide. Off-screen at any usable
zoom, and the selection's bounding box explodes horizontally, which is what the
user sees.

The doc comment is honest about the intent — *"cluster the rects into rows by
vertical overlap, then lay each row out left-to-right… Everything in one cluster
is a row; one item per cluster is a column; anything else is a grid"* — but "a
grid" only emerges when the input already *had* distinct rows. Tidy **preserves**
structure; it does not **impose** it. For a messy board there is no structure to
preserve, which is precisely when the user reaches for it.

### The wrap math already exists

`SpaceLayout.flowIn` (`SpaceLayout.swift:42-64`) flows aspects into justified rows
and **wraps at `maxRowWidth = 1600`** (`:28`), with `rowHeight = 240` and
`spacing = 16`. It is the app's established "lay N things out sensibly" answer —
used for bulk-add, for drop-at-point seeding, and for new-space seeding. It
normalises heights to `rowHeight`, so it is not directly reusable (tidy must
preserve sizes), but **the constant and the wrap rule are already decided**, and
tidy should not invent different ones.

## The design

### Keep the current behaviour where it is right

Tidy is genuinely correct on a small, already-structured selection: three tiles
roughly in a row snap to a row; a column snaps to a column. That is Figma's
⌃⌥⌘T, and the idempotence work behind it (`:126-146` — anchor at top-left,
strict-overlap clustering, smallest-observed gap) is careful and tested. **Do not
throw it away.**

### Add a width bound

Two changes, both in `tidy`:

1. **Wrap.** Carry a `maxWidth`; when placing an item would push the row past
   `box.minX + maxWidth`, start a new row. The default: the **selection's own
   bounding-box width** (`box.width`), falling back to `SpaceLayout.maxRowWidth`
   when the box is degenerate (everything piled at one point). Using the
   selection's own width is what preserves the small-selection behaviour for
   free — a selection already one row wide keeps its row, because its box is
   exactly that wide.

2. **Bound the row-clustering chain.** `openBottom` should be the *open row's
   band*, not its running maximum. Cluster against the row's **first** member's
   vertical extent (or the row's median), so a staircase breaks instead of
   chaining. This is the change that makes the "many items" case produce rows at
   all, before wrapping even applies.

Both preserve the idempotence constraint the current implementation is built
around, and the existing `allCases` "re-applying changes nothing" test is the
guard that proves it — a wrapped layout re-tidied must produce the same wrap,
which it does when the bound is the selection's post-tidy box width. **That is
the subtle part and it needs its own test**, because the box after a wrap is
narrower than the box before it: the bound must be captured from the *input* box
and re-derived identically on the second pass, or tidy creeps narrower on every
press.

Simplest way to guarantee that: derive the bound from the **total area** of the
rects rather than the current box — `maxWidth = sqrt(totalArea × targetAspect)`,
quantised. Same input rects → same bound, first pass or fifth, regardless of what
the box did. Worth prototyping against the box-width rule before committing.

### What "uniform grid" should mean

The request says "uniform grid". Two readings, and they are different features:

- **Wrapped rows preserving each tile's size** (above) — tiles keep their aspect
  and dimensions, rows have ragged right edges and varying heights. This is what
  Tidy Up means in every tool that has it, and it is what the current code is one
  bound away from.
- **A true uniform grid** — every tile forced to one cell size. That is
  destructive to the tiles' sizes and is a *different verb*. If wanted, it belongs
  beside Tidy in the spacing group (`SpaceArrangeGroups.swift`) as **"Grid"**,
  not as a change to Tidy.

Recommended: fix Tidy (wrapped rows) first; add "Grid" only if the fixed Tidy
still doesn't answer the need.

## Schema / migration impact

**None.** `CanvasArrange` is a pure `[CGRect] → [CGRect]` kernel with no model or
renderer coupling (`:1-11`), which is why this is cheap.

## Phased implementation

1. **T1 (S)** — row-clustering band fix + wrap bound in `tidy`; extend the
   existing kernel tests.
2. **T2 (XS)** — surface nothing new; the `spacing` group's Tidy button is
   unchanged (`SpaceArrangeGroups.swift`). Verify `minimumCount` (2) still holds.
3. **T3 (M, optional)** — a separate "Grid" op, if T1 proves insufficient.

## Test strategy

`CanvasArrange` is already table-driven over `Operation.allCases`, so this extends
an existing suite rather than starting one:

- **Idempotence** (the existing `allCases` test) must still pass — and gains a
  case at 60 rects, where it currently passes trivially because one row re-clusters
  into one row.
- Wrap: 60 uniform rects → ⌈60/k⌉ rows, no row exceeding the bound; last row
  ragged, left-aligned.
- Chain-breaking: a staircase of 10 rects each overlapping only its neighbour →
  **not** one row.
- Preserved cases: 3 rects already in a row → one row, unchanged spacing rule;
  3 in a column → three rows; a 2×2 grid → 2×2.
- Sizes preserved: every output rect's `size` equals its input's (this is the
  invariant that separates Tidy from "Grid").
- Degenerate: all rects at one point (zero-width box) → falls back to
  `SpaceLayout.maxRowWidth`, does not divide by zero, does not produce one row.
- Gap derivation unchanged (`tidyGap`, `:180-193`) — smallest observed, falling
  back to `defaultTidyGap` (20).

## Effort: **T1: S · T2: XS · T3: M (optional)**

## Risks & edge cases

- **Idempotence is the constraint**, not a nice property — the implementation
  comment says so, and a wrap bound derived from a value that changes between
  passes breaks it silently (the layout creeps every press). Test at N=60, not
  just N=4, or the creep is invisible.
- Undo: Tidy registers one undo entry ("Tidy Up", `:47`). A wrapped tidy moves
  more tiles; verify the undo restores all of them, not the pre-wrap subset.
- A selection mixing a huge frame with small tiles: the frame alone can exceed the
  bound. A row must always accept at least one item, or the loop never terminates.
- Text boxes and frames are tiles too on this canvas — they participate in
  arrange ops today and will participate in the wrap. Confirm that reads as
  intended, or exclude frames from the bound calculation.
- `SpaceLayout.maxRowWidth` is 1600 world units, chosen for flow-in of
  240-high rows. As a *fallback* for tidy it is arbitrary; say so in the code
  rather than implying it was derived.

## Open questions

1. Bound from the selection's box width, or from `sqrt(area × aspect)`?
   (Recommended: prototype both against the idempotence test at N=60; area-derived
   is the safer default.)
2. Target aspect for the area-derived bound — 16:9? the viewport's? (Recommended:
   a fixed 16:9, so the result doesn't depend on window size.)
3. Is a separate uniform **"Grid"** op wanted, or does fixed Tidy suffice?
4. Should Tidy respect the [066] exact-gap value from `SpaceSpacingPopover` when
   one has been set, instead of re-deriving the smallest observed gap?

# 066 — Tidy Up, and an exact gap

> Two ways to control spacing that the eight existing arrange ops could not express.
> Extends [051](./051-spaces-figma-plan.md)'s `CanvasArrange` kernel.

## 1. The problem

`CanvasArrange` aligns (6 ops) and distributes (2 ops). Distribution **equalises** the
gaps it finds while holding the outer bounding box fixed, so there was no way to say
either of the two things a user actually wants:

- *"clean this mess up"* — one click, no numbers;
- *"put exactly 24 between these"*.

## 2. Why this was cheap, and where the cost actually was

The geometry was nearly free. `distribute` already sorts by leading edge, derives a gap
and walks a cursor placing each rect; packing at a *chosen* gap changes one line. And
because the action bar is `ForEach(CanvasArrange.Operation.allCases)` with `actionName`
and `minimumCount` carried on each case, **a new op wires itself into the bar, the undo
name and the enablement gating for free**.

The cost was in the two places the kernel doesn't reach: deciding what "tidy" means, and
where a number gets typed.

## 3. Tidy Up

### 3.1 One algorithm, no mode inference

Row, column and grid are the same thing: **cluster the rects into rows by vertical
overlap, then lay each row out left-to-right**. Everything in one cluster is a row; one
item per cluster is a column; anything else is a grid. There is no mode to infer, so
there is no mode to infer *wrongly* — which is the failure a user would actually notice.

### 3.2 Idempotence is the design constraint

`CanvasArrangeTests` asserts *"every op is idempotent — re-applying changes nothing"*
over `allCases`, so `tidyUp` inherited that the moment it was added. It is also just
what the user expects: clicking Tidy Up twice must not creep.

Every rule is chosen to survive its own output:

| rule | why it survives a second pass |
| --- | --- |
| anchor on the selection's top-left | that corner does not move, so the box is unchanged |
| cluster on **strict** overlap | rows laid `gap` apart — even `gap == 0`, where they touch — re-cluster the same |
| gap = the **smallest** observed gap | afterwards every gap is exactly that, so re-deriving returns it |
| items in a row share a top edge | total overlap, so they re-cluster into the same row |

The gap rule is also the only one that never makes a layout *bigger* than the one the
user built. Overlaps contribute negative gaps and are ignored; a selection with no
measurable gap at all (everything stacked) falls back to `defaultTidyGap` rather than
collapsing onto a point — which is what the naive version does.

## 4. The exact gap

### 4.1 The enum stays closed

`Operation` is `CaseIterable` and the bar renders it with `ForEach(allCases)`. A case
carrying an associated value — `.packHorizontal(gap:)` — **cannot** be `CaseIterable`,
so adding one would break that wiring for all eight existing ops. Rather than pay that,
the gap gets its own entry point over the same kernel: `CanvasArrange.pack(_:axis:gap:)`
and `SpaceModel.pack(axis:gap:)`.

`Axis` moved from `private` to internal to carry it, which is the whole API cost.

### 4.2 One shared model body

`SpaceModel.arrange` and `SpaceModel.pack` both end in `applySelectionLayout`, extracted
from `arrange`'s own tail: live rects → transform → zip back by index → apply in memory →
`renderRevision` → one undo step at `reload: false`. Each of those is load-bearing and
each is easy to omit when writing a second copy, which is exactly why there is only one.

### 4.3 The control is a popover, and that is a correctness decision

**A focusable field in the action bar would have been a bug.** That bar floats *over the
canvas*, and a focused field there swallows keystrokes the canvas owns — ⌫ deletes the
selection, V/F/T switch tools. Two shipped bugs came from precisely this shape: **269**
(unmodified tool keys firing while typing into a text box) and **271** (the search
field's blur closing the canvas editor).

A popover is the shape the app already uses for focus-taking controls — font, size,
colour, `ElementInspector` — because a popover is *expected* to hold focus and hands it
back on dismiss. Inside one, autofocusing the field is safe and saves a click; in the bar
it would have been the bug.

First responder is returned to the canvas host explicitly on dismiss (via
`chromeAnchor.host`), deferred off the view update because `onDisappear` runs inside one
— the same trap `ElementInspector.onDisappear` already documents.

## 5. Files changed

- `AtelierRefs/AtelierRefs/CanvasArrange.swift` — `.tidyUp`, `tidy` / `tidyRows` /
  `tidyGap`, `pack`, `Axis` made internal
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `applySelectionLayout` extracted, `pack`
- new: `AtelierRefs/AtelierRefs/SpaceGapPopover.swift`
- `AtelierRefs/AtelierRefs/SpaceView.swift` — `gapButton`, the tidy symbol

## 6. Tests

`CanvasTidyPackTests` (14), plus everything `CanvasArrangeTests` now runs against
`.tidyUp` for free via `allCases` — count/size preserved, idempotent, no-op below the
minimum, and the `minimumCount`/`isDistribute` invariant.

The ones that would catch a real regression:

- **stability across four shapes** — grid, column, flush-at-gap-0, and fully
  overlapping. The generic idempotence test covers one fixture; these are the shapes
  most likely to break it.
- **fully overlapping falls back to the default** and genuinely spreads out, rather
  than collapsing onto one point.
- **pack orders by leading edge, not array order** — a selection arrives from a `Set`.
- **a negative gap clamps** to flush.

## 7. Manual verification

1. Scatter 5–6 items, select all, **Tidy Up** → a clean grid at the tightest spacing
   you already had. Click again → nothing moves.
2. Tidy a horizontal row and a vertical column → each keeps its shape.
3. Select 3 items, open **Gap**, type 24, click **Across** → exactly 24 between edges.
   ⌘Z restores in one step.
4. **The regression that matters:** open the Gap popover, click into the field, press
   Escape to dismiss, then press ⌫ and V/F/T — the selection must delete and the tools
   must switch. If any of those are dead, focus did not come back.

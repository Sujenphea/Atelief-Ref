# 288 — the board's top bar, aligned with the collection's

## Summary

`SpaceView`'s header carried three things a collection's header does not: a permanent
"Drag to place · pinch to zoom" hint, the export progress ring, and the Export button
— all above a `Divider`, at a 12pt margin instead of the collection's 24pt. Opening a
board after a collection shifted the title down and left, and the board was the only
screen whose header was interactive.

It is now **name + count**, the same two rows `CollectionView.headerContent` renders,
at the same type, gap and 24pt content margin, with no rule beneath it. The export
moved down into the floating action bar — the same place the collection raises its
contact-sheet export from.

| | before | after |
| --- | --- | --- |
| header | name · N items · hint · ring · Export | name · N items |
| margins | 12 horizontal / 8 vertical, `Divider` below | 24 horizontal, 24 top / 12 bottom, no rule |
| export | top-bar `Label` button, popover opens down | floating-bar glyph, popover opens up |

## Changes

### `SpaceView`

`header` is the collection's `HStack(spacing: 10)` — tail-truncating title plus a
secondary `.callout` count — and the `Divider` between it and the canvas is gone.

The count is redacted until the board's first read resolves, so it can't flash
"0 items" at a board that has some. The collection redacts for the same reason by a
different route: its `items` belong to whichever collection last loaded, whereas a
`SpaceModel` is built per board and simply has no `space` yet.

New `exportBar` — `MoodboardExportButton` + `ExportProgressRing` — appended to
`actionBar` **outside** its `barMode` switch, so it is mode-invariant like
undo/redo. That is the right shape for it: an export is selection-or-whole-board
(052 · B3), so it means the same thing at every selection size. The ring renders
nothing while idle, so it costs no width the rest of the time.

The `File ▸ Export Moodboard…` focused-scene value is untouched.

New `barSeparator` — a 1×16 `hairlineStrong` rule with 5pt either side — sits between
the mode-switched half and the export. Semantically it marks an act that leaves the
app (the idiom the "+" menu already uses above "New Space from Collection"), but it
also fixes a measured defect; see below.

### Why the export needed a rule in front of it

The bar's `spacing: 2` is not the gap you see. Every glyph is a 30×28
`SelectionBarIcon` whose 15pt symbol carries ~7.5pt of its own air, so neighbouring
glyphs read ~17pt apart and the capsule's trailing margin reads ~24pt.

The segmented `toolPicker` is the ONE child with no internal margin — its bezel is a
hard edge. Appending the export directly after it left, in `.idle`:

| gap | before the rule | after |
| --- | --- | --- |
| picker bezel → export glyph | 11pt | ~21pt |
| export glyph → capsule edge | 24pt | 24pt |

— the button read as jammed against the tools and adrift from the edge. It never
showed before because the picker used to be the last child, with only the capsule
beyond it. Measured off a rendered bar, not estimated.

Two things this was NOT, both checked and ruled out: the idle `ExportProgressRing`
costs no width (a `Group` whose branches all fail contributes no subview, so the
stack adds no spacing for it — verified at 62.0pt with and without), and the
`.padding(.trailing, 10)` + chrome inset is genuinely symmetric with the leading one
(23.5pt vs 24pt, glyph to capsule edge).

### `MoodboardExportControls`

`MoodboardExportButton` now renders a `SelectionBarIcon` rather than a `Label`, and
its popover uses `arrowEdge: .top` so it opens **above** the floating bar instead of
downward off the window edge — matching `ContactSheetExportButton`, which already
did both. `.plain` drops the system's disabled dimming, so the empty-board /
mid-export state is an explicit `.opacity(0.35)`, the idiom the rest of the bar's
buttons follow.

`ExportProgressRing`'s cancel popover also flipped to `arrowEdge: .top`. Both of its
call sites are floating bottom bars now — the collection's selection bar has been
one all along, where a downward popover was already wrong.

## Files changed

- `AtelierRefs/AtelierRefs/SpaceView.swift`
- `AtelierRefs/AtelierRefs/MoodboardExportControls.swift`

## Migration notes

None. `MoodboardExportButton` has one call site and no API change; it is styled for
a floating bar now, so dropping it back into a toolbar would look wrong.

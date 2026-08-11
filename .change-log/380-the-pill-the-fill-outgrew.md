# 380 — The Pill the Fill Outgrew

Styling follow-up to [379](379-the-palette-you-can-open.md), all of it found by
looking at the thing on screen rather than at the code: the toolbar had grown a
fourth button tier, the palette's chips had drifted from the app's standard chip,
and the hover fill was drawing outside the pill it lived in.

## 1 · The toolbar is its own tier, and it did not have one

The app has three glyph-button tiers — the sidebar rail (14–15pt glyph, 5pt pad),
inline-in-a-card (12pt, `xs`), and inside the search field (12/8pt, 3/2). The
toolbar had a fourth, used by `FavoritesFilterChip` alone: a 12pt glyph at `xs`
padding on the 7pt `control` radius — an inline chip's padding wearing a chrome
button's corner, the only place in the app pairing them. `ColorFilterPicker`
copied it.

**Aligning it to the sidebar rail was the wrong first answer**, and the screen said
so. The rail is a bare button in a custom strip, so 5pt of pad is its whole visual
margin and reads fine. A macOS 26 `ToolbarItem` is drawn inside a glass pill that
**hugs its content**, so the button's own padding becomes the pill's margin — at 5
the glyph was cramped against its own capsule.

That hugging causes two faults a plain `HoverButtonStyle` cannot avoid there:

1. **The fill overhung the pill.** `HoverHighlight` pads the glyph and fills that
   padded rect — which is the same rectangle the pill hugs. So the fill's 7pt
   corners sat against the far rounder capsule macOS draws, and poked out past it.
   Shrinking the padding cannot fix this: it shrinks both rects together.
2. **Two buttons were two widths.** SF Symbols have different intrinsic widths —
   `paintpalette` is visibly wider than `star` — so a content-hugging pill inherits
   whichever symbol it holds, and the two toolbar buttons were different sizes.

`ToolbarGlyphButtonStyle` fixes both by construction: the glyph is pinned to a fixed
box, so every toolbar pill is one size whatever its symbol; and the hover fill is a
capsule **inset 2pt from the pill**, so it cannot overhang whatever radius the
system picks. The radius is derived from the box and the padding rather than written
down, so it stays a capsule if either is retuned.

The pill is **38×30 — wider than tall**, which is what a toolbar button looks like
on macOS and what `Theme.Radius.control` already assumed ("a 15pt icon in a 30×28
hit area"). A square pill reads squat. The width was found by widening until it
stopped looking tight, not by picking a ratio.

Both toolbar buttons share the style, so this cannot drift apart again.

## 2 · One chip face, not two

`ColorSwatchChip` (C2) and `ColorFilterChip` (C3) are the same shape — dot, name,
chip background — and had been written twice. **They had already drifted** before
anyone put them side by side: different item spacing, different vertical padding,
and a 10pt dot against a 12pt one.

The drift had a cause worth naming. The picker's chips were shrunk below every other
chip in the app to fit three columns in a popover whose width had been *guessed* at
260 — the layout dictating the component instead of the other way round.

`ColorChipFace` is now the one face, at `DetailChip`'s metrics (`sm` spacing, `sm`
horizontal, `xs + 2` vertical, `Radius.chip`). The wrappers keep only what genuinely
differs: the detail chip paints the IMAGE's hex and carries a coverage tooltip, the
picker's paints the BUCKET's reference hex and has a selected state.

Its one departure from `DetailChip` — a hairline border — is carried from C2 and
kept deliberately: a chip whose content IS a color needs an edge of its own, or the
dot's ring reads as the chip's border and a `#ffffff` swatch dissolves into the fill.

The popover width is now derived from the chip rather than the chip from the width:
three chips of ~83pt, plus the column gaps, plus the popover's padding.

## Tests

**None added, and none exist to add.** The app target's suite is model logic; there
are no view-metric or snapshot tests, so nothing here is assertable without
inventing a testing approach the repo does not have. `ColorPalette.filterOrder`'s
tests already guard what the picker *contains*; this changes only how it measures.

The full app suite passes unchanged.

## Files changed

- `AtelierRefs`: `HoverButtonStyle.swift` (new `ToolbarGlyphButtonStyle`),
  `ColorSwatchRow.swift` (new `ColorChipFace`), `ColorFilterPicker.swift`,
  `LibrarySearch.swift`

## Migration notes

Nothing to run. `FavoritesFilterChip` changes size on screen — that is the point:
it was the one button holding the fourth tier open.

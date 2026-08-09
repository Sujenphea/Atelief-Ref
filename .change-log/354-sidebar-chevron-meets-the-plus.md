# 354 · The sidebar chevron finally meets the "+"

## Summary

A sub-collection's disclosure chevron sat **6pt right** of the "+" it shares a
column with in the Collections / Spaces section headers. The two glyphs are laid
out by different frameworks on either side of one seam, and nothing named the
seam, so the measurement on each side had been taken against something else.

The header "+" is a 12pt glyph in `HoverHighlight`'s 6pt pad against the sidebar's
`Spacing.lg` content edge — it centres 28pt in from the sidebar's trailing edge.
The row chevron is a 20pt button pinned 4pt inside a cell whose outline view
deliberately overhangs that content edge by 8pt — it centred at 22pt. The `-4`
came from 074 · S1, where it preserved the *pre-button* glyph's 8pt inset, a
number inherited from the decorative `NSImageView` and never checked against the
header above it.

## Changes

**`SidebarOutlineKit.swift`**

- **`SidebarMetrics.outlineOverhang`** — the 8pt both outline views extend into
  the sidebar's trailing padding, named because it is now measured ACROSS: it was
  a literal on the SwiftUI side and an assumption on the AppKit side, which is
  precisely how the two drifted.
- **`SidebarCell.chevronInset`** is derived, not written down:
  `headerGlyphCenter (16 + 6 + 6) - outlineOverhang (8) - halfButton (10)` = 10.
  Centres, not edges — `chevron.right` is 9pt wide and `chevron.down` 14pt, so an
  edge-aligned glyph would shift sideways on every toggle. The 20pt hit area is a
  named constant too rather than three separate `20`s.
- **`SidebarChevronButton`** — 074 · S1 gave the chevron a real 20pt hit area but
  no hover state, so the one genuinely clickable target in the row looked as inert
  as the label beside it; the row's own `hoverRow` fill underneath reads as "this
  ROW is hoverable", the opposite of what splitting the interaction was for. This
  is the AppKit half of `HoverButtonStyle`: `hoverControl` at `Radius.control`, a
  step up from the row fill it sits on. It carries `SidebarRowView`'s tracking-area
  reconcile for the same reason — cells are recycled, and `mouseEntered` never
  fires for a pointer that was already inside.

**`SidebarView.swift`** — both outline views take
`-SidebarMetrics.outlineOverhang` instead of `-8`.

**`Theme.swift`** — `NS.hoverControl` joins the AppKit mirrors, since a seam now
reads it (the rule that enum states for adding one back).

## Migration notes

None. Spaces rows configure `expandable: false`, so their chevron stays hidden and
neither change reaches them.

## Status

Build + full unit suite green.

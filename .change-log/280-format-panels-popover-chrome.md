# 280 — Format panels wear the app's popover chrome

## Summary

The Space format bubble's four panels (align / font / size / colour) were styled as
more BUBBLE — `field` fill, `hairlineStrong` border, the floating bar's hand-rolled
shadow — so a Space panel and a Collection `…` overflow popover were visibly
different greys. They now share one container.

- New `popoverChrome(cornerRadius:)` in `Theme.swift`: `surface` fill, plain
  `hairline` border, `.elevation(.hover)`. A popover floats over content it did not
  lay out, so its separation comes from the shadow rather than a heavy border — the
  opposite balance to a floating BAR, which sits in known space and can afford
  `hairlineStrong`.
- `selectionMenuChrome()` is now that modifier plus its own padding / fixed width /
  `presentationBackground(.clear)`, so there is ONE definition of the look.
- The bubble itself keeps the bar tokens (renamed `panelChrome` → `bubbleChrome`):
  it belongs to the box it formats and tracks it, where a panel is a transient layer
  over the board. `field` on `surface` is the app's existing bar-on-popover contrast.
- `FontFamilyPicker`'s selected row moves from `Color.accentColor.opacity(0.15)` to
  `Theme.Colors.selection` — the token the sidebar and search results already use.
  The app is monochrome by design, and a translucent tint also shifted colour once
  the list moved onto the new surface. This affects the element inspector's copy of
  the picker too, which is the point: the two ways into the setting match again.

## Files changed

- `AtelierRefs/AtelierRefs/Theme.swift` — `popoverChrome(cornerRadius:)`.
- `AtelierRefs/AtelierRefs/SelectionActionBar.swift` — `selectionMenuChrome()`
  delegates to it.
- `AtelierRefs/AtelierRefs/SpaceFormatChrome.swift` — panels use `popoverChrome`,
  `panelChrome` → `bubbleChrome` (bubble only).
- `AtelierRefs/AtelierRefs/FontFamilyPicker.swift` — selected row token + `chip`
  radius.

## Migration notes

- New popovers should use `popoverChrome()` rather than hand-rolling a fill +
  border + shadow. Pass a radius only for a non-card shape (the align panel passes
  its pill radius).
- Still outside the shared look: `SpaceGapPopover` and the other system `.popover`
  call sites use SwiftUI's own chrome with only padding of their own.
- The three floating BARS (`selectionBarChrome`, `bubbleChrome`, `ImportProgressPill`)
  still hardcode `0.35 / 14 / 5` instead of a `Theme.Elevation` token.

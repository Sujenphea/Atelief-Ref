# 231 — Grid selection affordances readable on light images

## Summary

In the collection detail grid, a selected cell's border and checkmark were both a
single flat accent color with no contrast backing, so they nearly disappeared
against light/bright thumbnails. Added a light-or-dark contrast element to each so
the selection reads on any image:

- **Border** — a `black@0.25` hairline nested just inside the 3pt accent ring
  (`selectionContrastLayer`). Gives the border a luminance edge on pale photos;
  invisible on dark ones. Sized inset by the ring width, clipped to the tile.
- **Checkmark** — palette rendering (`SymbolConfiguration(paletteColors:)`) so the
  tick is BLACK on an accent-filled circle, instead of a monochrome accent tint
  whose knocked-out check read the backing photo. Added a soft drop shadow on the
  circle button so its edge survives any backing (also carries the white empty-state
  ring while hovering).
- **Image dim** — a `black@0.18` scrim (`selectionScrimLayer`) painted over a
  selected thumbnail, below the rings/circle. Photos-style "pull the image back" cue
  that both reads as selection on its own and makes the ring + tick pop.

## Files changed

- `AtelierRefs/AtelierRefs/MasonryGridItem.swift`
  - New `selectionScrimLayer` and `selectionContrastLayer` (each declared, set up in
    `loadView`, sized in `viewDidLayout`, toggled in `applySelectionState`).
  - New `selectionRingWidth` constant (was the magic `3`).
  - `circleButton` shadow added in `loadView`.
  - `applySelectionState` picks the black-tick palette checkmark when selected.

## Migration notes

None — purely visual, layer-only, no API or state-model change. The SwiftUI
`SharedThumbnail.swift` tiles (media-less card kinds / previews) still draw the
old accent-only border; mirror this there if the same contrast is wanted for those.

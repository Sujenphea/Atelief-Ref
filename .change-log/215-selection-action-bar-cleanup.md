# 215 — Selection action bar cleanup

## Summary

Redesigned the floating "N selected" action bar to match the reference: a
monochrome capsule with a leading count, an `×` clear, then an evenly-sized row of
action glyphs. Extracted a shared component so the Collection and Search bars stay
identical instead of drifting.

- New `SelectionActionBar.swift`: `SelectionBarIcon` (fixed 30×28 glyph with a
  subtle rounded hover fill), `SelectionBarButton` (action wrapper), and a
  `.selectionBarChrome()` modifier (solid `Theme.Colors.field` capsule,
  `hairlineStrong` border, elevation, bottom inset).
- Chrome uses a SOLID token fill, not `.regularMaterial`: a translucent material
  tinted from each grid's backdrop, so the Collection and Search bars rendered
  slightly different greys. The fixed token makes both pixel-identical and matches
  the reference's opaque pill.
- **Collection bar** (`CollectionView`): `"Clear"` text → `×` icon placed right
  after the count; reordered to `× · trash · folder-minus · ⋯` (reference order);
  `ellipsis.circle` → plain `ellipsis`. The `…` popover restyled with leading
  icons, tighter rows, a divider before Set as Cover, and a wider min width.
- **Search bar** (`LibrarySearch`) and **Home bar** (`CollectionsGalleryView`):
  adopt the same shared chrome and icon buttons (`× · trash`), replacing their
  inline `"Clear"` text + ad-hoc capsule.

Icons stay monochrome ink (`.plain` + `.primary`) — the destructive Delete is not
tinted; its confirmation still lives in the `requestDelete` model call.

## Files changed

- `AtelierRefs/AtelierRefs/SelectionActionBar.swift` (new)
- `AtelierRefs/AtelierRefs/CollectionView.swift` (`selectionBar`, `moreActionsMenu`)
- `AtelierRefs/AtelierRefs/LibrarySearch.swift` (`selectionBar`)
- `AtelierRefs/AtelierRefs/CollectionsGalleryView.swift` (`selectionBar`)

## Migration notes

None. Pure UI; every button calls the same model methods as before.

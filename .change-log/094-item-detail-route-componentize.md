# 094 — Item detail: route via NavModel + componentize sidebar

The full-window item-detail overlay (`084`) was driven by a *local* `showDetail`
flag on `CollectionView`, and its sidebar was one 170-line struct. This makes the
overlay shared route state and splits the sidebar into sections — the enabling
refactor for the tags editor and the Enter / canvas open paths
([023-item-detail-plan](../.docs/023-item-detail-plan.md), F1). No behaviour
change.

## Summary

- **Route via `NavModel.presentedItemID`** (previously "Reserved for 006",
  unused): `CollectionView` drops its `@State showDetail` and presents the overlay
  on `nav.presentedItemID != nil && model.selectedItem != nil`. A new `open(_:)`
  helper (select + set `presentedItemID`) is the single seam every entry point
  funnels through — the grid click today, the Return key and Space canvas next
  (F3). Back / Escape clears `presentedItemID`; the `selectedItem != nil` guard
  still auto-dismisses when the item is deleted from inside the page.
- **Componentized `DetailSidebar`**: the three sections became their own subviews
  — `MetadataSection`, `ProvenanceSection`, `ActionsSection` — over shared
  `DetailSection` / `DetailRow` building blocks and a `DetailFormat` helper (size
  / date / duration / platform). `DetailSidebar` is now a thin stack; the tags
  editor slots in between provenance and actions with no further surgery.

## Files changed

- `AtelierRefs/AtelierRefs/CollectionView.swift` — remove `showDetail`; overlay +
  grid cell route through `nav.presentedItemID` via a new `open(_:)` helper.
- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — split `DetailSidebar` into
  section subviews + shared `DetailSection` / `DetailRow` / `DetailFormat`.

## Migration notes

None — pure refactor. The overlay opens, navigates (prev/next), and
auto-dismisses exactly as before; `NavModel.presentedItemID` is now live rather
than reserved.

## Tests

App builds clean (`AtelierRefs` scheme, Xcode 26). No behaviour change, so no new
tests; the existing suites remain green.

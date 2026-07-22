# 196 — Remove the collection drop rail

## Summary

Removed the floating trailing drop rail (`009 · N5`) that appeared on every
collection screen except Unsorted. Assets now route out of a collection via the
sidebar space/collection rows and the per-cell "Add to" / "Move to" context
menus — the rail's routing was redundant with those paths.

## Files changed

- **Deleted** `AtelierRefs/AtelierRefs/CollectionDropRail.swift` — the rail view.
- `CollectionView.swift` — dropped the rail render branch (the
  `collectionID != unsortedFolderID` gate), the `dropRail` view builder, the
  now-dead `handleCollectionDrop`, and the `.task` that refreshed collection
  covers solely for the rail's mini thumbnails. `moveTargets` stays — the grid's
  per-cell context menus still consume it.
- `SidebarView.swift`, `CollectionTargets.swift`, `AssetDragPayload.swift`,
  `MasonryGridHost.swift`, `CollectionsGalleryView.swift` — updated doc comments
  and dangling `` ``CollectionDropRail`` `` DocC links that referenced the rail.

## Migration notes

- No behavior change to drop routing itself: `moveToCollection` / `copyToCollection`
  and the shared `AssetDragPayload` / `routeDrop` path are untouched.
- `CollectionStackCard.swift` remains orphaned (already unused after the earlier
  Unsorted stack-row removal) — left as-is; out of scope for this change.
- `model.collectionCovers` is still refreshed by `CollectionsGalleryView`; only
  the CollectionView-side refresh (rail-only) was removed.

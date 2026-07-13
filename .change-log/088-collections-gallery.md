# 088 — Collections gallery (004-P2)

The app's home screen: a gallery of the ROOT collections as cover cards, the
drill-down entry point for the new shell (087). Replaces the persistent folder
tree.

## Summary

- **`CollectionsGalleryView`** (new): a `LazyVGrid` of `CoverCard`s over the root
  collections. The protected **Unsorted** folder is pinned as the first card
  (004 Q2); the rest sort by name. Tapping a card pushes its `CollectionView`.
  Card context menus: New Subfolder / Rename / Delete (Rename & Delete hidden for
  Unsorted, F3). A toolbar "+" creates a new root collection. Name entry uses
  simple `.alert` text-field prompts.
- **`AppServices.collectionCovers(_:)`** (Core, 086): batch collection → cover
  `blob_hash` lookup so cards resolve their on-disk cover thumbnail in one query.
- **`IngestionModel`**: `collectionCovers` published map + `refreshCollectionCovers()`
  + `setCollectionCover(collectionID:assetID:)` (the grid's "Set as Cover" action).

## Files changed

- Added: `CollectionsGalleryView.swift`
- Edited: `IngestionModel.swift` (cover state + refresh + set-cover)
- Core (086): `AppServices.collectionCovers(_:)` + `ServicesSpaceTests` coverage

## Migration notes

None. Cover *setting* already existed (`setCollectionCover`); this surfaces it and
adds the batch read. Collections with no (surviving) cover show a folder
placeholder card.

## Tests

`collectionCovers` covered in `AtelierCoreTests/ServicesSpaceTests` (maps only
collections with a surviving cover; empty input → empty). Gallery view is
compile-only (repo convention).

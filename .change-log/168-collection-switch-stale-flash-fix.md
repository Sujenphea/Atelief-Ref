# 168 — Collection switch flashed the previous collection's items

## Summary

Moving from one collection into another flashed the *previous* collection's grid
for a beat before the current collection's items appeared. The detail pane is
driven by a **single shared `IngestionModel.items`** array with nothing recording
which collection those items belong to, so a freshly-pushed `CollectionView` was
born reading the outgoing collection's items: `NavigationStack` renders the new
screen immediately, but the reload only starts a runloop later (deferred via
`DispatchQueue.main.async` to avoid the "update multiple times per frame" nav
crash) and finishes after an async DB read. That whole gap rendered stale
content. The title was already correct because it derives from the view's own
`collectionID`; the grid, header count, subfolder chips, and stack row all read
the shared model and lagged.

Fix: give the shared items an **identity**, and gate the view on it.

- `IngestionModel` gains `loadedCollectionID`, stamped at the exact point `items`
  is published for a collection. It flips to the new collection only when that
  collection's data actually lands.
- `CollectionView.isLoaded` compares `loadedCollectionID` to its own
  `collectionID`. Until they match, the grid shows a **masonry-shaped skeleton**
  (`gridSkeleton`) instead of the stale items, the header count is redacted, and
  the subfolder chips / stack row are withheld. The "No items in this collection
  yet" empty state now only shows once loaded, so it can't flash mid-switch.

Because the gate reads "not mine yet" from the view's very first frame, the
deferred publish no longer needs any timing change — the skeleton covers both the
deferred frame and the async-read latency. In-place reloads (move/delete within
the same folder) keep `loadedCollectionID` equal, so they never flash a skeleton.

## Files changed

- `AtelierRefs/AtelierRefs/IngestionModel.swift` — added
  `@Published private(set) var loadedCollectionID: UUID?`; set alongside `items`
  in `loadContents`.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — added `isLoaded` gate,
  `gridSkeleton(width:)`, and `loadedGrid(geo:)` (extracted from `grid` so the
  grid can swap in the skeleton); gated the header count (redacted), subfolder
  chips, stack row, and the empty-state overlay on `isLoaded`.

## Migration notes

None. `loadedCollectionID` starts `nil` (first load shows the skeleton rather
than an empty/stale grid), and no persisted state or public API changed.

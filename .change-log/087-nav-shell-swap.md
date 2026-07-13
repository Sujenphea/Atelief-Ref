# 087 — Navigation redesign: shell swap (004-P1)

Replaces the 3-tab `TabView` (Canvas / Library / Sweeps) with a top-bar
`NavigationStack` shell: **Collections gallery → Collection → Spaces → Space**.
Sweeps and Browser Capture move to the window toolbar; the persistent folder
tree is dropped (drilling in uses subfolder chips + a breadcrumb helper).

## Summary

- **`NavModel`** (new): route state only — `path: [AppRoute]` (`.collection` /
  `.spaces` / `.space`) + `presentedItemID` (reserved for 006). Pure, testable
  `collectionBreadcrumb(for:in:)` ancestor-chain helper (cycle-safe). Relaunch
  restore reopens the last-viewed collection once folders load (004 Q3).
- **`AppShellView`** (new): the `NavigationStack` + `navigationDestination`
  routing + the app-level toolbar (Spaces entry, Sweeps sheet, Browser Capture
  popover, relocated from the old `LibraryView`). Publishes a `focusedSceneValue`
  so the menu Back command can reach the current `NavModel`.
- **`CollectionView`** (new): the old `LibraryView` detail, extracted — header +
  drop target + navigable subfolder chips + item grid + import (drop / ⌘V) +
  the item-detail overlay (local flag until 006). Subfolder chips now PUSH a
  route instead of mutating a shared selection. Adds "New Space from Collection"
  and "Set as Cover".
- **`ContentView`** shrinks to host `AppShellView`; keeps the shared error alert
  + destructive-delete confirmation wrapping the whole shell so errors surface
  from any screen (G1 preserved). `minWidth` 960 → 860 (single column now).
- **`AtelierRefsApp`**: a Back menu command (`⌘[`) that pops the focused `NavModel`.
- **`IngestionModel`**: `store` / `services` exposed read-only (for `SpaceModel`);
  folder-canvas methods (`canvasContent()`, `moveCanvasTile`) removed;
  `rootCollections`, `items(in:)`, `thumbnailURL(forBlobHash:)` added.
- **`SharedThumbnail`** (new): `ThumbnailCache` + `AsyncThumbnail` + `CoverCard`,
  extracted from `LibraryView` so the gallery / grid / Spaces list share one
  off-main decode path.

## Files changed

- Added: `NavModel.swift`, `AppShellView.swift`, `CollectionView.swift`, `SharedThumbnail.swift`
- Edited: `ContentView.swift`, `AtelierRefsApp.swift`, `IngestionModel.swift`
- **Deleted**: `CanvasScreen.swift` (folder-canvas UI — the canvas↔folder link is
  removed, 005), `LibraryView.swift` (replaced by `CollectionView` +
  `CollectionsGalleryView`)
- Added tests: `AtelierRefsTests/NavModelTests.swift` (breadcrumb + route intents)

## Notes / gotchas

- `FolderTreeView.swift` is now unreferenced (only `LibraryView` used it). Left in
  place — it still compiles — pending an explicit cleanup pass; the settled
  direction ships without the tree (004 Q1).
- `CanvasContent.swift` + its tests are retained: `SpaceContent` is modelled on it
  and `SpaceLayout` reuses its justified-rows math.

## Migration notes

UI-only; no schema change. Users land on the Collections gallery (or their
last-opened collection). The `collection_item.canvas_*` columns remain dormant.

## Tests

App target builds clean (`xcodebuild -scheme AtelierRefs`). New `NavModelTests`
cover the breadcrumb (nested / root / unknown / cycle) and route intents
(push / pop / idempotent / no-op at root).

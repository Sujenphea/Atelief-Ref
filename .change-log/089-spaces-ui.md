# 089 — Spaces UI (005-E2)

Ships first-class Spaces end-to-end on top of the E1 core (086) and the new nav
shell (087): a Spaces list, an open-space canvas that reuses the real renderer,
"Add from Library", and "New Space from this collection" seeding. **Zero renderer
changes** — asset tiles ride the existing pooled/culled/LOD path (decision T3).

## Summary

- **`SpaceContent`** (new): the `SpaceItem`-backed `TileProvider` + `TileImageSource`,
  the space sibling of `CanvasContent`. Maps a space's ASSET rows to `Tile`s from
  their persisted placement (a space_item always has a rect). Freeform ELEMENT
  rows (`.frame`/`.text`) are intentionally skipped in v1 — they need the vector
  tile path that lands in E3; they round-trip in the store untouched.
- **`SpaceModel`** (new): the per-open-space view model (deliberately NOT more
  `IngestionModel`) over the shared `AppServices` + `MediaStore`. Holds the
  space's rows + selection + the cached `SpaceContent`; drag persists via
  `setSpaceItemPlacement` (in-memory update first so the tile stays put); remove
  drops the placement (never the asset); "Add from Library" flows assets in.
- **`SpaceLayout`** (new, pure/testable): justified-rows `flowIn(...)` for a batch
  of added assets, and `placements(seedingFrom:)` for seeding a space from a
  collection (honours explicit folder-canvas placement, flows the rest below) —
  mirroring `CanvasContent.layout`.
- **`SpacesListView`** (new): spaces as cover cards (New Space, rename, delete);
  tap opens the space.
- **`SpaceView`** (new): the open space over `CanvasView` (select / drag / remove /
  video QuickLook), an empty state, and the "Add from Library" toolbar action.
- **`AddFromLibrarySheet`** (new): pick a collection, multi-select its items, add
  them to the space (loads items without disturbing the main selected-folder state).
- **`IngestionModel`**: `spaces` + `spaceCovers` published state, `refreshSpaces`,
  `createSpace` / `renameSpace` / `deleteSpace`, `newSpaceFromCollection(_:)`
  (seed + set first item as cover), and `makeSpaceModel(for:)`.
- **Core (086)**: `AppServices.spaceCovers(_:)` for the list cards.

## Files changed

- Added: `SpaceContent.swift`, `SpaceModel.swift`, `SpaceLayout.swift`,
  `SpacesListView.swift`, `SpaceView.swift`, `AddFromLibrarySheet.swift`
- Edited: `IngestionModel.swift` (spaces surface + `makeSpaceModel`)
- Core (086): `AppServices.spaceCovers(_:)`
- Added tests: `AtelierRefsTests/SpaceLayoutTests.swift` (flow-in / seeding /
  `SpaceContent` tile mapping)

## Scope

v1 = Space entity + asset placement + freeform arrangement, per the confirmed
scope. **Deferred**: E3 (frames + text tools — needs a non-image tile path in the
benchmark-gated `CanvasEngine`) and E4 (shapes). Element rows are already modelled
+ validated in the core (086) so E3 is additive.

## Migration notes

None beyond the v4 schema (086). Deleting an asset elsewhere vacates its space
placements via the FK cascade; the open-space live-refresh on external change is
a known follow-up (mirrors `handleRemoteCapture`).

## Tests

`SpaceLayoutTests` (flow packing/wrap/z, seed honours placement + flows below,
`SpaceContent` maps asset rows / skips element rows / selection round-trip /
in-memory move). App target builds clean and the app-target test suite passes.

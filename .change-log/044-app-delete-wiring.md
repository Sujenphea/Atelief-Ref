# 044 — App: delete/remove wiring across inspector, grid, and canvas

## Summary

Surfaces the delete feature end-to-end. `IngestionModel` gains the orchestration
and one shared confirmation state; the three views trigger it.

- **`IngestionModel`**
  - `removeFromFolder(assetIDs:)` / `removeSelectedFromFolder()` — membership-only
    drop from the current folder (via `AppServices.removeAssets`). Immediate,
    reversible, no confirmation.
  - `requestDelete(assetIDs:)` / `requestDeleteSelected()` — stage a destructive
    delete into `pendingDeletion`.
  - `confirmPendingDeletion()` — `AppServices.deleteAssets`, then trash the
    returned orphaned blobs via `MediaReaper` **off the main actor**, then refresh
    the tree + reload the folder. `cancelPendingDeletion()` dismisses.
  - `PendingDeletion` state + a private `mutateContents` helper (refresh + reload
    + status) shared by remove and delete.
- **`CanvasContent`** — `detail(forTileID:)` and `tileID(forItemID:)` expose the
  tile ↔ item mapping (tile.id is the index into the details) so the canvas can
  resolve a clicked tile to its asset and reflect the shared selection.
- **`CanvasScreen`** — single-click selects (shared with the Library selection),
  right-click Remove/Delete, ⌫/Delete key delete; `selectedTileID(in:)` mirrors
  the inspector's selection into the highlight. (Adds `import AtelierCore`.)
- **`InspectorView`** — a *Remove from Folder* button and a destructive *Delete*.
- **`LibraryView`** — grid thumbnails get a Remove/Delete context menu and the
  grid honours the ⌫/Delete key (`onDeleteCommand`) on the selection.
- **`ContentView`** — one `confirmationDialog` bound to `pendingDeletion`, shared
  by all three surfaces, warning that files go to the Trash and the asset leaves
  every folder.

## Files changed

- `AtelierRefs/AtelierRefs/IngestionModel.swift`
- `AtelierRefs/AtelierRefs/CanvasContent.swift`
- `AtelierRefs/AtelierRefs/CanvasScreen.swift`
- `AtelierRefs/AtelierRefs/InspectorView.swift`
- `AtelierRefs/AtelierRefs/LibraryView.swift`
- `AtelierRefs/AtelierRefs/ContentView.swift`
- `AtelierRefs/AtelierRefsTests/CanvasContentMappingTests.swift` (new) — 3 tests
  guarding the tile ↔ item mapping (round-trip, inversion, out-of-range → nil) so
  a canvas delete can never hit the wrong asset.

## Migration notes

None. The app builds against macOS 26 (`xcodebuild ... -scheme AtelierRefs`).
Deletes move orphaned files to the system Trash (recoverable); remove-from-folder
touches only membership.

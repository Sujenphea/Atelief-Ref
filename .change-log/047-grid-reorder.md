# 047 — Drag-to-reorder for the Library grid

## Summary

The Library grid's item order was fixed at import order (or whatever
`manual_order` the core last assigned). This adds **drag-to-reorder** so you can
drag a thumbnail onto another to change its position within the current folder,
and the new order **persists**:

- Drag a thumbnail and drop it onto another cell to move it there.
- Insertion is **directional**: dragging forward the item lands just **after**
  the target; dragging backward, just **before**. So an **adjacent drop swaps**
  the two and there is no dead zone (dropping onto an immediate neighbour always
  does something).
- The reorder is **optimistic** — the grid updates instantly, then the new full
  order is persisted via the existing `AppServices.setGridOrder` seam (the write
  runs off the main actor). On failure the message surfaces through the existing
  `lastError` alert and the folder reloads to the truth.
- Reorder coexists with the existing arrow-key navigation, click-to-select,
  `.onDeleteCommand`, the context menu, and the inspector. Selection is tracked
  by membership id, so it survives the reorder untouched.

Only the currently selected folder's direct items are reordered — no
special-casing beyond what the model already exposes.

## What changed

- **Pure reorder math** (SwiftUI-free, unit-tested):
  - `reorderedIDs(ids:movingID:toIndexOf:)` — given the folder's ordered asset
    ids, the dragged id, and the drop-target id, returns the new full ordering.
    Directional: forward drops land after the target, backward drops before it,
    so adjacent drops swap. Returns `nil` for a no-op (drop onto itself, or a
    foreign drop whose payload isn't one of the folder's items). A non-nil result
    is always a same-count permutation of the input.
- **Model wiring** (`IngestionModel.reorderItem(movingAssetID:toIndexOf:)`):
  - Computes the new order via `reorderedIDs`, reorders the local `items` array
    optimistically (rebuilt from an `assetID → detail` map, bumping
    `contentsVersion` so the Canvas tab tracks the change), then persists via
    `services.setGridOrder(collectionID:orderedAssetIDs:)` in a `Task` (the
    async write hops off the main actor). On error it sets `lastError`; either
    way it reloads through the existing `loadContents(of:)` path (core sorts by
    `manual_order`, so local state stays consistent with the persisted truth).
- **Grid wiring** (`LibraryView.grid`):
  - Each cell gains `.draggable(detail.asset.id.uuidString)` and
    `.dropDestination(for: String.self)`. A thin private `reorder(dropped:onto:)`
    parses the payload back to a `UUID` and calls `model.reorderItem`; a
    malformed / foreign payload is rejected (and the model no-ops on a
    non-member id), so text dropped from outside can't scramble the order.

## Files changed

- `AtelierRefs/AtelierRefs/GridReorder.swift` (new) — the pure
  `reorderedIDs(ids:movingID:toIndexOf:)` helper.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — new
  `reorderItem(movingAssetID:toIndexOf:)` (optimistic reorder + persist + reload).
- `AtelierRefs/AtelierRefs/LibraryView.swift` — `.draggable` + `.dropDestination`
  on each grid cell and the private `reorder(dropped:onto:)` drop glue.
- `AtelierRefs/AtelierRefsTests/GridReorderTests.swift` (new) — 9 tests over the
  pure helper.

No `AtelierCore` change — the `setGridOrder` seam was already in place.

## Verification

- `cd AtelierRefs && xcodebuild -project AtelierRefs.xcodeproj -scheme AtelierRefs
  -destination 'platform=macOS' build` — **BUILD SUCCEEDED**.
- `xcodebuild … test -only-testing:AtelierRefsTests` — **TEST SUCCEEDED**, 22
  tests passed (9 new `GridReorderTests`, plus the existing 9 `GridNavigation`, 3
  `CanvasContentMapping`, 1 example). The new tests cover forward / backward
  moves, move-to-front, move-onto-last, adjacent swap, self-drop → `nil`,
  unknown moving / target id → `nil`, and the same-count-permutation invariant.
- The SwiftUI drag-and-drop wiring (`.draggable` / `.dropDestination`) is
  **compile-verified only** — no runtime GUI test; a manual drag click-through
  remains pending (consistent with the repo's runtime-UI-verification-pending
  note in 046).

## Migration notes

None. Additive behaviour; no schema, data, or public-API change. Reuses the
existing `AppServices.setGridOrder` seam and the model's `loadContents` reload
path. New app-target files (`GridReorder.swift`, `GridReorderTests.swift`) are
picked up automatically by the project's file-system-synchronized groups — no
`.xcodeproj` edit. Arrow-key navigation, click-to-select, `.onDeleteCommand`,
the context menu, and the inspector are all preserved.

Tradeoff — the drag payload is the asset id's `uuidString` carried as a plain
`String` (`.draggable` / `.dropDestination(for: String.self)`) rather than a
custom `Transferable` UTType, which would need an Info.plist type declaration.
The parse-and-membership guard makes a foreign string drop a safe no-op, and the
grid's `String` drop type doesn't overlap the folder drop zone's
`[.image, .fileURL, .url]`, so the two never contend.

# 254 — Spaces import: SP2 library drag onto a board

Phase SP2 of the [059 import-into-spaces plan](../.docs/059-spaces-import-plan.md) —
the first user-visible surface: drag existing references (a grid multi-select,
library search results, or another board) onto an OPEN Space canvas and they land
centred on the cursor. No ingest, no dedup — pure placement of assets that already
exist. External file/image/URL import is SP3.

## Summary

- **Batch asset insert (13A).** `AppServices.addAssetsToSpace(_:to:)` +
  `SpaceAssetPlacement` — the INSERT analog of the shipped `setSpaceItemPlacements`
  batch UPDATE. Validates the space once and every placement up front, then mints N
  `space_item` rows in ONE transaction (all-or-nothing: an unknown asset / bad rect
  rolls the whole batch back). Replaces the per-row insert loop.
- **Shared placement pipeline (6A).** `SpaceModel.insertPlaced(_:seededAt:)` is now
  the ONE writer behind both `addAssets` (seed `.belowContent`) and the new
  `placeDroppedAssets(ids:at:)` (seed `.point`, centred on the drop). It flows via
  `SpaceLayout.flowIn`, batch-inserts (13A), registers the placement-only undo (S2),
  and does a single reload (14A).
- **AppKit drop seam (4A).** `CanvasHostView` gains a generic
  `NSDraggingDestination`: `acceptedDropTypes` + `onDragEntered` + `onDrop`. The
  host computes the WORLD drop point via the same `CanvasTransform` hit-testing uses
  (decision C6 — no drift), then hands the app the pasteboard + point. `CanvasView`
  exposes the seam. The renderer package stays ignorant of the app's payload types
  (layering preserved); AppKit — not SwiftUI `.onDrop` — so the drop composes with
  the canvas's existing pan / marquee / tile-drag gestures.
- **SpaceView wiring.** Registers `AssetDragPayload.pasteboardType`, decodes the
  drag off the pasteboard, routes through the pure `canvasDropRoute` (SP1), and on
  `.place` calls `placeDroppedAssets`. `.ingestThenPlace` (external) is refused for
  now — SP3.

## Files changed

- `AtelierCore/Sources/AtelierCore/Services/ServiceTypes.swift` — new
  `SpaceAssetPlacement`.
- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` — new batch
  `addAssetsToSpace(_:to:)`.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — drop-seam
  properties + `NSDraggingDestination` overrides.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasView.swift` — seam exposed
  through the SwiftUI wrapper.
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `PlacementSeed`, `insertPlaced`,
  `placeDroppedAssets`; `addAssets` refactored onto the shared pipeline.
- `AtelierRefs/AtelierRefs/AssetDragPayload.swift` — `decode(from: NSPasteboard)`.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — drop wiring (`import AppKit`).
- Tests: `AtelierCoreTests/ServicesSpaceTests.swift` (batch insert matrix),
  `AtelierRefsTests/SpaceImportPlaceTests.swift` (pipeline + centred drop + S2 undo).

## Migration notes

None. `addAssets`'s external behaviour is unchanged (same below-content flow, same
undo name/shape) — it now routes through the shared writer and the batch insert, so
an add is one transaction + one reload instead of N. No schema change. The
`IngestionModel.addAssetsToSpace(assetIDs:to:)` SIDEBAR drag-to-space path is
untouched (still its own loop) — folding it onto the batch method is a candidate DRY
follow-up, deferred to keep SP2 scoped to the open-board surface.

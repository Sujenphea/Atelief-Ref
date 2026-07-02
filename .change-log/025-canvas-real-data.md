# 025 — Canvas on real data (build-order #5)

## Summary

The **Canvas tab now renders the selected folder's real images** instead of the
Phase-1 dummy tiles. Pan/zoom, viewport culling, and LOD are inherited unchanged
from the spike — we drove the renderer from real data through the seams the spike
left open (decision A2), with no renderer rewrite. Pick a folder in the Library,
switch to Canvas, and see it laid out. See `.docs/010-canvas-realdata-overview.md`.

## What changed

### CanvasRenderer package — second seam (behaviour-preserving)
- **New `TileImageSource` protocol** (`imageKey(for:)`, `imageData(for:tier:)`) —
  the image-content seam alongside the existing `TileProvider` geometry seam.
- `CanvasEngine.images` is now `any TileImageSource` (was the concrete
  `FixtureImageSet`); the per-frame sync + benchmark warm route through the
  protocol. `FixtureImageSet` conforms with identical behaviour (`imageKey` =
  `id % count`, tier-independent `imageData`), so all 67 tests + the benchmark
  stay green.
- `CanvasHostView` / `CanvasView` generalized to `any TileProvider` +
  `any TileImageSource`.

### App — real-data provider + wiring
- **`CanvasContent`** (new) conforms to both seams over `[CollectionItemDetail]`
  + `MediaStore`: justified-rows auto-layout (honours explicit `canvas_*`),
  `Tile.id` = item index, per-blob-hash cache key (dedup), LOD tier → pre-
  generated thumbnail tier (128/512/1280).
- **`CanvasScreen`** (new) — the Canvas tab: header (folder name + count),
  `CanvasView` over `CanvasContent`, empty state, rebuild on `contentsVersion`.
- **`ContentView`** — `IngestionModel` lifted here and **shared** by both tabs
  (one DB connection; both show the same selected folder). Dummy spike tab
  removed.
- **`IngestionModel`** — `contentsVersion` (bumped when `items` reload) +
  cached `canvasContent()` (rebuilt only when the version changes).
- **`LibraryView`** — takes an injected `@ObservedObject` model (was its own
  `@StateObject`).

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/TileImageSource.swift` — new protocol.
- `CanvasRenderer/Sources/CanvasRenderer/Spike/FixtureImages.swift` — conform.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` — use the seam.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift`,
  `Host/CanvasView.swift` — generalize to the protocols.
- `AtelierRefs/AtelierRefs/CanvasContent.swift` — new real-data provider.
- `AtelierRefs/AtelierRefs/CanvasScreen.swift` — new Canvas tab view.
- `AtelierRefs/AtelierRefs/ContentView.swift` — shared model, real Canvas tab.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — canvas content + version.
- `AtelierRefs/AtelierRefs/LibraryView.swift` — injected model.

## Verification

- `swift test` (CanvasRenderer): **67 passed** (incl. `measure {}` benchmark).
- `xcodebuild -scheme AtelierRefs`: **BUILD SUCCEEDED**, no Sendable warnings.
- SwiftUI/AppKit host wiring is compile-verified only — a manual pan/zoom over a
  real folder is pending.

## Caveats / migration notes

- No schema/data change; additive package protocol + app views.
- **Thumbnail reads are on the main thread** before the off-main decode — the
  005 "re-profile with real assets" trigger. If panning janks, move the read
  off-main via a `@Sendable () -> Data?` provider (localized `DecodeScheduler`
  change). Profile with Instruments first.
- No canvas editing / placement persistence yet; rebuilding on import resets
  pan/zoom. Both are later canvas-editor work.

# 009 — MVP Status: Checklist (done / to do)

> A living checklist of what's shipped versus what remains, reconciled from the
> foundation plan ([004](./004-foundation-plan.md) build order + roadmap) against
> the per-checkpoint record in `.change-log/`. Companion decision records:
> canvas [005](./005-canvas-overview.md), data core [006](./006-datacore-overview.md),
> ingestion [007](./007-ingestion-overview.md), folders [008](./008-folders-overview.md).
>
> Legend: ✅ done · 🟡 partial · ⬜ not started · ⏸️ deferred (designed-for).
> Status as of the latest `.change-log/` entry (`022-folders-ui`).

## MVP definition of done (the target)

> paste/drag/extension-capture an image → it downloads and stores locally with
> its source → it appears in a collection → view it in **grid and canvas** → and
> from anywhere **open the original source**. Fast, no spinners.

Loop status: capture ✅ · store ✅ · organize ✅ · **view** 🟡 (grid partial,
canvas not on real data, no per-image open) · **open source** ⬜.

## Build order (004 §recommended build order)

### 1. Canvas rendering spike — ✅ done
De-risked the #1 critical-path risk. Verdict: Core Animation is sufficient at MVP
scale (~4.6 ms/frame vs 8.33 ms budget, ~45% headroom); Metal deferred with a
documented fallback. See [005](./005-canvas-overview.md), `.change-log/001`–`008`.
- [x] `CanvasRenderer` local Swift Package, wired into the Xcode project
- [x] Pure logic: `CanvasTransform`, `TileCuller`, `LODPolicy`, `Tile`
- [x] `TileProvider` seam (the swap point for real data at step 5)
- [x] CA host: `CanvasEngine`, `LayerPool`, `ThumbnailCache`, `DecodeScheduler`
- [x] 66 Swift Testing cases + layer-pool invariants + `measure {}` benchmark gate
- [ ] Manual Instruments pass (Core Animation + Allocations) before ship — *pending*

### 2. Data core + GRDB store — ✅ done
`AtelierCore` package, **152 tests**, on main. See [006](./006-datacore-overview.md),
`.change-log/009`–`014`, `020`–`021`.
- [x] Domain models: Asset, Source, Collection, CollectionItem, Tag, AssetTag, JSONValue
- [x] Schema + `DatabaseMigrator` (v1 + v2), append-only versioned
- [x] Content-addressed persistence records; explicit snake_case `CodingKeys`
- [x] Single **App Services** mutation path (writes funnel + reads)
- [x] FTS5 search (`searchAssets`)
- [x] Dedup by content hash; many-to-many membership without blob duplication

### 3. Ingestion pipeline + direct input — ✅ done
`AtelierIngestion` package, **59 tests**, on main. See [007](./007-ingestion-overview.md),
`.change-log/015`–`019`.
- [x] Content-addressed, sharded, atomic, idempotent `MediaStore`
- [x] SHA-256 streamed hashing; ImageIO metadata + EXIF orientation
- [x] Thumbnail tiers (128/512/1280), JPEG decode-to-size
- [x] `IngestPipeline` (blob-first, hash-first short-circuit, never throws)
- [x] `IngestCoordinator` (bounded concurrency, progress, cancel-safe)
- [x] Direct input: paste / drag (file or browser image) → correct provenance
- [x] Paste bug fixed — reads the real file, not the icon/QuickLook preview
- [ ] ⏸️ **Link resolution (fallback)** — paste a bare post/pin URL → resolve media
      + provenance. Explicitly deferred (007 §scope); MVP-in-scope but not built.

### 4. Grid view — 🟡 partial
A `LazyVGrid` thumbnail grid of a folder's direct items exists in `LibraryView`
(via the folders UI). The full MVP grid is more than this.
- [x] Thumbnail grid of a collection's items (512-tier thumbnails)
- [x] Empty / loading / placeholder tile states
- [ ] Virtualized for large collections (perf at scale)
- [ ] Reorderable
- [ ] Selection + keyboard navigation
- [ ] Open an item from the grid (→ ties into #7 inspector/preview)

### 5. Infinite canvas on real data — ⬜ not started
The renderer is built and benchmarked (#1) but still drives **dummy tiles**.
Productionizing = swapping the `TileProvider` seam for a `CollectionItem`-backed
provider and hosting it in the app.
- [ ] `CollectionItem`-backed `TileProvider` (map `canvas_x/y/w/h/z` → `Tile`)
- [ ] Host `CanvasView` in the app against a real collection
- [ ] Persist tile placement (canvas coordinates) back through App Services
- [ ] Re-profile with real, variable-size assets (005 caveat)

### 6. Chrome extension + localhost endpoint — ⬜ not started
The primary platform-ingestion path (Twitter / Pinterest / Instagram / Cosmos)
and the seam the future agent reuses.
- [ ] Localhost HTTP endpoint over the App Services mutation path
- [ ] Chrome extension: capture current post/pin via the authenticated session
- [ ] Per-site content scripts (provenance extraction)
- [ ] POST full provenance → ingest through the shared pipeline

### 7. Inspector + provenance actions — ⬜ not started
Closes the loop's tail: look at an image and get back to where it came from.
- [ ] Full-resolution preview of a selected asset
- [ ] Metadata panel (dimensions, format, capture time, platform, source)
- [ ] **Open original source** action (the always-reachable provenance link)
- [ ] Reachable from grid (and later canvas)

## Beyond the numbered build order

### Folders (organisation) — ✅ done
Not a numbered build-order item, but realises the "Library + Collections"
surface. See [008](./008-folders-overview.md), `.change-log/020`–`022`.
- [x] Nested folders via `parent_collection_id` (v2 migration, cascade)
- [x] Boards-style many-to-many membership
- [x] Protected "Unsorted" default import target
- [x] Delete a folder → delete the whole subtree
- [x] Reparent with cycle prevention
- [x] Folder-tree sidebar UI (create / subfolder / rename / delete / move)
- [ ] ⏸️ Drag images between folders — *nice-to-have, deprioritised* (services
      already support it via `addAssets` / `removeAssets`; needs draggable
      thumbnails + droppable sidebar folders)

## Cross-cutting / not yet verified
- [ ] **Runtime UI verification** — all SwiftUI is compile-verified only; no GUI
      auto-tests. A manual run-through of the app is pending.
- [ ] XCUITest UI flows (drag-drop, grid interaction, inspector) — 004 §testing.

## Deferred to later phases (designed-for, not MVP)
- ⏸️ **Phase 2** — bulk import / backfill per platform; extension breadth
  (Safari/Firefox); auth + rate-limit robustness; video polish; dedup review UI.
- ⏸️ **Phase 3** — Tags UI + filtering (schema reserved); external agent
  interface (localhost API → CLI/HTTP → MCP); new-ingest inbox / triage.
- ⏸️ **Phase 4** — canvas richness (grouping, snapping, connections, LOD tuning);
  more views (timeline, source-grouped, graph); smart / nested collections;
  quick-capture (global hotkey, share/menu-bar).
- ⏸️ **Phase 5** — sync / backup; export; collection sharing.

## Suggested next priority
Per the loop status, the missing tail is **viewing**: build-order **#7
(Inspector + preview + open-source)** completes the "view a ref and open its
source" promise for the least effort, then **#5 (canvas on real data)** — the
app's signature view — then **#6 (Chrome extension)**, the largest and most
self-contained.

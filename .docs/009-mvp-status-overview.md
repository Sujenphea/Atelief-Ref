# 009 — MVP Status: Checklist (done / to do)

> A living checklist of what's shipped versus what remains, reconciled from the
> foundation plan ([004](./004-foundation-plan.md) build order + roadmap) against
> the per-checkpoint record in `.change-log/`. Companion decision records:
> canvas [005](./005-canvas-overview.md), data core [006](./006-datacore-overview.md),
> ingestion [007](./007-ingestion-overview.md), folders [008](./008-folders-overview.md).
>
> Legend: ✅ done · 🟡 partial · ⬜ not started · ⏸️ deferred (designed-for).
> Status as of the latest `.change-log/` entry (`083-production-process-cleanup`).
> **Reconciled 2026-07-13** against docs [020](./020-production-readiness-overview.md) /
> [021](./021-production-readiness-plan.md) and Phases 1–3 + 5 of the production-readiness
> fix roadmap (changelogs `079`–`083`). Phase 4 (distribution) is deferred.

## MVP definition of done (the target)

> paste/drag/extension-capture an image → it downloads and stores locally with
> its source → it appears in a collection → view it in **grid and canvas** → and
> from anywhere **open the original source**. Fast, no spinners.

Loop status: capture ✅ (paste/drag + bare-URL download #B1 + **Chrome extension**
#6 + **bulk sweep** popup/engine) · store ✅ · organize ✅ · **view** ✅ (grid +
inspector + canvas on real data) · **open source** ✅. Core MVP is code-complete
(~710 unit tests). Production-readiness Phases 1–2 (P0/P1 gaps G1–G10) landed in
`.change-log/080`–`081`. Remaining: finish manual E2E (019), XCUITest smoke (G11
in progress), distribution edge deferred (Phase 4 / G12–G14).

## Verification pass (2026-07-03)

Three read-the-source verifications + a build/test run, reconciling this doc
against reality:
- **Foundation** — every claimed architectural piece exists; `AtelierCore` 162,
  `AtelierIngestion` 84, `CanvasRenderer` 78/79, `AtelierServer` 44 tests; app
  **BUILD SUCCEEDED**. Two test-only flakes found and fixed this session
  (`.change-log/048`, `049`) — the suite is now deterministic.
- **Viewing loop** — inspector, grid selection/open, `.inspector()` panel all
  present as claimed.
- **Canvas + B1** — canvas real-data confirmed; B1 URL download was genuinely
  missing and has now been built (`.change-log/045`).

## Build order (004 §recommended build order)

### 1. Canvas rendering spike — ✅ done
De-risked the #1 critical-path risk. Verdict: Core Animation is sufficient at MVP
scale (~4.6 ms/frame vs 8.33 ms budget, ~45% headroom); Metal deferred with a
documented fallback. See [005](./005-canvas-overview.md), `.change-log/001`–`008`.
- [x] `CanvasRenderer` local Swift Package, wired into the Xcode project
- [x] Pure logic: `CanvasTransform`, `TileCuller`, `LODPolicy`, `Tile`
- [x] `TileProvider` seam (the swap point for real data at step 5)
- [x] CA host: `CanvasEngine`, `LayerPool`, `ThumbnailCache`, `DecodeScheduler`
- [x] Swift Testing cases + layer-pool invariants + `measure {}` benchmark gate
- [x] Test determinism hardened — T12 asserts seed-governed dimensions (exact
      decoded pixels are not a reliable CI gate under parallel CG load);
      the async `DecodeScheduler` test awaits `onDecoded` instead of a fixed sleep
      (`.change-log/048`, `049`, `080`)
- [ ] Manual Instruments pass (Core Animation + Allocations) before ship — *pending*

### 2. Data core + GRDB store — ✅ done
`AtelierCore` package, **162 tests**, on main. See [006](./006-datacore-overview.md),
`.change-log/009`–`014`, `020`–`021`, `041`.
- [x] Domain models: Asset, Source, Collection, CollectionItem, Tag, AssetTag, JSONValue
- [x] Schema + `DatabaseMigrator` (v1 + v2), append-only versioned
- [x] Content-addressed persistence records; explicit snake_case `CodingKeys`
- [x] Single **App Services** mutation path (writes funnel + reads)
- [x] FTS5 search (`searchAssets`)
- [x] Dedup by content hash; many-to-many membership without blob duplication
- [x] `deleteAssets` with dedup-safe blob GC (`OrphanedBlob`) (`.change-log/041`)
- [x] `setGridOrder` (persist `manual_order` in one transaction) — grid reorder seam

### 3. Ingestion pipeline + direct input — ✅ done
`AtelierIngestion` package, **84 tests**, on main. See [007](./007-ingestion-overview.md),
`.change-log/015`–`019`, `033`–`034`, `042`, `045`.
- [x] Content-addressed, sharded, atomic, idempotent `MediaStore`
- [x] SHA-256 streamed hashing; ImageIO metadata + EXIF orientation
- [x] Thumbnail tiers (128/512/1280), JPEG decode-to-size
- [x] `IngestPipeline` (blob-first, hash-first short-circuit, never throws)
- [x] `IngestCoordinator` (bounded concurrency, progress, cancel-safe)
- [x] Direct input: paste / drag (file or browser image) → correct provenance
- [x] Paste bug fixed — reads the real file, not the icon/QuickLook preview
- [x] Video pipeline + remote-video factory (`.change-log/033`–`034`)
- [x] `MediaReaper` trashes orphaned blob files after delete (`.change-log/042`)
- [x] **Direct image URL download** — `RemoteImageFetcher` (injectable, unit-tested;
      sniffs actual bytes via `ImageMetadata`, not the server Content-Type)
      resolves a bare image URL → `.web` provenance (`.change-log/045`, was **B1**)
- [ ] ⏸️ **Page-URL link resolution** — paste/drag a *page* URL that needs HTML
      scraping to find the media. Still deferred (007 §scope); the Chrome extension
      (#6) covers the platform cases. Only bare *image* URLs are handled (above).

### 4. Grid view — ✅ done (MVP scope)
`LazyVGrid` thumbnail grid of a folder's direct items in `LibraryView`, now with
selection, keyboard nav, and drag-to-reorder. See `.change-log/023`, `046`, `047`.
- [x] Thumbnail grid of a collection's items (512-tier thumbnails)
- [x] Empty / loading / placeholder tile states
- [x] Virtualized for large collections (native `LazyVGrid` lazy realization)
- [x] Selection + open an item (drives the inspector) (`.change-log/023`)
- [x] Keyboard navigation — arrow keys move selection, scroll-into-view; pure
      `GridNavigation` helper + tests (`.change-log/046`)
- [x] Reorderable — drag-to-reorder, persists `manual_order` via `setGridOrder`;
      pure directional-insertion helper + tests (`.change-log/047`)

### 5. Infinite canvas on real data — 🟡 mostly done
The Canvas tab renders the selected folder's real images through the spike's
seams (see [010](./010-canvas-realdata-overview.md), `.change-log/025`). Viewing
works; editing/persistence and real-data profiling remain.
- [x] `CollectionItem`-backed provider (`CanvasContent` — both renderer seams)
- [x] New image-content seam `TileImageSource` (renderer no longer fixture-bound)
- [x] Host `CanvasView` in the app against the selected folder (shared model)
- [x] Justified-rows auto-layout; honours explicit `canvas_*` when present
- [x] Persist tile placement (canvas coordinates) back through App Services —
      **drag-to-place** editor: drag a tile to reposition; in-memory provider
      mutation keeps pan/zoom (no rebuild) and `canvas_x/y/w/h/z` persist via
      `setCanvasPlacement`, so the layout survives folder switch + relaunch
      (`.change-log/050`)
- [x] Main-thread thumbnail file I/O removed from the pan/zoom sync path — disk
      URLs load via `DecodeScheduler` off-main (`.change-log/081`, G7). Manual
      Instruments confirmation still recommended before ship.
- [ ] Manual Instruments pass (Core Animation + Allocations) on real variable-size
      assets — *pending*

### 6. Chrome extension + localhost endpoint — ✅ done
The primary platform-ingestion path (Twitter / Pinterest / Instagram / Cosmos),
image + video, and the seam the future agent reuses. See
[011](./011-capture-extension-overview.md), `.change-log/026`–`040`.
- [x] Localhost HTTP endpoint (`AtelierServer` / FlyingFox) over the shared pipeline
      — `/ingest`, `/ingest-video`, `/health`; **44 tests**
- [x] `network.server` sandbox entitlement; endpoint wired into `IngestionModel`
- [x] Token (`X-Atelier-Token`) + `Origin` auth gate + CORS/preflight; body cap
- [x] Chrome extension (MV3): capture current post/pin via the authenticated session
- [x] Per-site extractors (Twitter/Pinterest/Instagram/Cosmos + web fallback)
- [x] Video capture path (Twitter/Pinterest incl. story/idea pins) (`.change-log/032`–`040`)
- [x] POST bytes + full provenance → `DirectInputReader` → ingest
- [ ] Manual pass: run the signed app + load the unpacked extension end-to-end

### 7. Inspector + provenance actions — ✅ done
Closes the loop's tail: look at an image and get back to where it came from.
See `.change-log/023`.
- [x] Preview of a selected asset (1280-tier thumbnail, loaded off-main)
- [x] Metadata panel (kind, dimensions, size, MIME, capture time; platform,
      author/handle, title, original URL)
- [x] **Open Original Source** action (disabled when there's no `originalURL`)
- [x] Open Full Resolution, Reveal in Finder, Copy Source Link
- [x] Reachable from the grid (selection); native `.inspector()` panel + toolbar toggle

## Beyond the numbered build order

### Folders (organisation) — ✅ done
See [008](./008-folders-overview.md), `.change-log/020`–`022`.
- [x] Nested folders via `parent_collection_id` (v2 migration, cascade)
- [x] Boards-style many-to-many membership
- [x] Protected "Unsorted" default import target
- [x] Delete a folder → delete the whole subtree
- [x] Reparent with cycle prevention
- [x] Folder-tree sidebar UI (create / subfolder / rename / delete / move)
- [ ] ⏸️ Drag images between folders — *nice-to-have, deprioritised* (services
      already support it via `addAssets` / `removeAssets`; needs draggable
      thumbnails + droppable sidebar folders)

### Delete / remove assets — ✅ done
Remove-from-folder + destructive delete from inspector, grid, and canvas.
See `.change-log/041`–`044`.
- [x] `deleteAssets` core path with dedup-safe blob GC
- [x] `MediaReaper` trashes orphaned blob files off-thread
- [x] Canvas tile selection with remove/delete affordances
- [x] Delete/remove wiring across inspector, grid, canvas

## Cross-cutting / not yet verified
- [x] **XCUITest smoke** — launch + tab switch + Library Unsorted chrome
      (`.change-log/082`, G11). Deeper drag/inspector flows still manual.
- [ ] Full manual E2E — remaining unticked cases in [019](./019-bulk-import-verification.md).
- [ ] Instruments profiling pass (canvas pan/zoom on real assets; allocations).
- [ ] Distribution edge deferred — extension icons/package (G12), notarization /
      deployment target (G13), privacy/listing (G14), extension-id pin (G17).

## Production readiness (020/021)

| Phase | Status | Changelog |
|---|---|---|
| 5a WIP land (G15) | ✅ | `079` |
| 1 P0 bugs (G1–G5) | ✅ | `080` |
| 2 P1 hardening (G6–G10) | ✅ | `081` |
| 3 Runtime validation (G11 + 019) | 🟡 | `082` (UI smoke); manual E2E remaining |
| 4 Distribution (G12–G14, G17) | ⏸️ deferred | — |
| 5b Process (G16, G18) | ✅ | `083` |

## Suggested next priority
Finish remaining [019](./019-bulk-import-verification.md) live cases (T3, T7, T13–T16
unticked items) and an Instruments canvas pass. Then distribution (Phase 4) when
ready to hand the app to another user.

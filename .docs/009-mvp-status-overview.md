# 009 — MVP Status: Checklist (done / to do)

> A living checklist of what's shipped versus what remains, reconciled from the
> foundation plan ([004](./004-foundation-plan.md) build order + roadmap) against
> the per-checkpoint record in `.change-log/`. Companion decision records:
> canvas [005](./005-canvas-overview.md), data core [006](./006-datacore-overview.md),
> ingestion [007](./007-ingestion-overview.md), folders [008](./008-folders-overview.md).
>
> Legend: ✅ done · 🟡 partial · ⬜ not started · ⏸️ deferred (designed-for).
> Status as of the latest `.change-log/` entry (`049-decodescheduler-test-await`).
> **Reconciled + verified 2026-07-03** against real source (this doc was previously
> frozen at `022` and understated progress — inspector, canvas-real-data, grid
> selection, the extension, delete, and the B1 URL download had all landed since).

## MVP definition of done (the target)

> paste/drag/extension-capture an image → it downloads and stores locally with
> its source → it appears in a collection → view it in **grid and canvas** → and
> from anywhere **open the original source**. Fast, no spinners.

Loop status: capture ✅ (paste/drag + bare-URL download #B1 + **Chrome extension**
#6) · store ✅ · organize ✅ · **view** ✅ (grid + inspector + canvas on real data) ·
**open source** ✅ (inspector: Open Original Source). **All MVP build-order items
complete and verified in code** (282 package tests green, `AtelierRefs` BUILD
SUCCEEDED under Xcode 26). The remaining gates are **manual/runtime** (a hands-on
end-to-end pass, an Instruments profile) — no automated coverage of the GUI yet.

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
- [x] Test determinism hardened — T12 asserts decoded pixels not encoder bytes;
      the async `DecodeScheduler` test awaits `onDecoded` instead of a fixed sleep
      (`.change-log/048`, `049`)
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
- [ ] Persist tile placement (canvas coordinates) back through App Services — the
      `setCanvasPlacement` seam exists but no UI calls it; needs a drag-to-place
      canvas editor (later, Phase 4)
- [ ] ⏸️ Re-profile with real, variable-size assets (005 caveat): the thumbnail
      `Data(contentsOf:)` read is still **on the main thread** before the off-main
      decode (`CanvasContent.swift:89`). **Profile with Instruments first** — do
      not move it off-main speculatively; only if panning janks.

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
- [ ] **Runtime UI verification** — all SwiftUI is compile-verified only; no GUI
      auto-tests. A manual run-through of the app is pending. This is now the
      single largest gap between "green in CI" and "known to work."
- [ ] XCUITest UI flows (drag-drop reorder, keyboard nav, inspector) — 004 §testing.
- [ ] Instruments profiling pass (canvas pan/zoom on real assets; allocations).

## Backlog (reported gaps)

- [x] **B1 — Drag/paste an image *URL*.** ✅ Done (`.change-log/045`). A dragged or
      pasted bare image URL now downloads the bytes (`RemoteImageFetcher`) and
      ingests with the URL as `.web` provenance; an unreadable drop reports via the
      status line instead of a silent no-op. Scope: **direct image URLs only** — a
      *page* URL needing HTML scraping stays with the extension / deferred
      link-resolution (#3).

## Deferred to later phases (designed-for, not MVP)
- ⏸️ **Phase 2** — bulk import / backfill per platform; extension breadth
  (Safari/Firefox); auth + rate-limit robustness; video polish; dedup review UI;
  page-URL link resolution (HTML scraping).
- ⏸️ **Phase 3** — Tags UI + filtering (schema reserved); external agent
  interface (localhost API → CLI/HTTP → MCP); new-ingest inbox / triage.
- ⏸️ **Phase 4** — canvas richness (grouping, snapping, connections, LOD tuning);
  **canvas placement persistence + drag-to-place editor** (the `setCanvasPlacement`
  seam is ready); more views (timeline, source-grouped, graph); smart / nested
  collections; quick-capture (global hotkey, share/menu-bar).
- ⏸️ **Phase 5** — sync / backup; export; collection sharing.

## Suggested next priority
All MVP build-order items are code-complete and CI-green. The remaining MVP work is
**runtime validation, not features**: a manual end-to-end pass (signed app + unpacked
extension → real Twitter/Pinterest capture; drag/paste incl. bare image URL; grid
select/nav/reorder; inspector open-source; canvas pan/zoom) plus an Instruments
profile of canvas on real assets (which also settles the #5 main-thread-read
question with data rather than a guess). After that, polish: canvas placement
persistence (Phase 4) and the deferred page-URL link resolution.

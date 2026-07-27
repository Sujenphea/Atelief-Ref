# 058 — Import into Spaces: Drop / Drag / Paste onto the Canvas

> Bring references onto a Space's canvas from sources beyond today's single
> library-picker sheet: external files/URLs dropped on the board, library items
> dragged straight onto it, and clipboard paste. Placement is **at the drop
> point**. **Zero schema** — every piece reuses an existing seam (ingestion
> pipeline, `addAssetToSpace`, content-hash dedup, `DecodeScheduler`, the
> `deleteAssets`/`MediaReaper` guarded delete).
>
> **Design decisions were reviewed** across Architecture, Code Quality, Tests, and
> Performance (16 decisions, tagged `1A`–`16A` below and referenced throughout).

## Current state (verified)

- **One way in, and it's a modal.** The only path onto a board is
  `AddFromLibrarySheet` (`AddFromLibrarySheet.swift`) → `SpaceModel.addAssets`
  (`SpaceModel.swift:544`) → `AppServices.addAssetToSpace` (`AppServices.swift:1873`).
  It picks *already-ingested* assets from a chosen collection and **flows them in
  below the current content** (`SpaceLayout.flowIn`, seeded at `maxBottom + spacing`).
  No placement at a chosen location; nothing outside the library can enter a space.
- **`SpaceView` has no drop targets.** No `onDrop` / `dropDestination` /
  `registerForDraggedTypes` in the canvas — a Finder file, browser image, dragged
  web URL, or grid cell dropped on the board is silently ignored (snap-back).
- **The import machinery exists — but is private to collections.** `135-grid-accepts-drops`
  made the collection pane a drop target: `DirectInputReader.inputs(from:into:now:)`
  (AtelierIngestion, **shared**) decodes `[.image, .fileURL, .url]` providers into
  `[IngestInput]`; **`CollectionView.dispatch(inputs:webURL:undecoded:)`
  (`CollectionView.swift:719`) is a _private view method_** that ingests into a
  collection and mutates view-local progress state. `paste()`/`handleDrop()`
  (`CollectionView.swift:729/759`) share it. Web-URL resolution
  (`IngestionModel.resolveLinkAndIngest`, `ingestRemoteImage:2046`, `addLink:2156`)
  is wired.
- **Placement is a solved primitive.** `addAssetToSpace` takes explicit `x/y/w/h/z`
  guarded by `Validation.canvasPlacement` and **validates `Asset.exists`**
  (`AppServices.swift:1886`) — a placement requires an existing asset row.
  `SpaceLayout.aspect` sizes a cell; `SpaceLayout.flowIn` packs a set from a start.
- **The canvas is AppKit-hosted.** `CanvasHostView` already handles `copy(_:)` via
  the responder chain (`236`), and the grid moved to **AppKit-level drop**
  (`191`/`192-appkit-grid-drop-fix`) because SwiftUI drop couldn't coexist with
  AppKit interaction. The renderer already owns a **screen→world transform** for
  tile hit-testing, a `DecodeScheduler` (`049`), and a pool/culler.
- **Payload typing is disambiguated.** The grid drag carries a typed
  `AssetDragPayload` (`assetIDs` + `sourceCollectionID`); `SpaceDragPayload` is
  sidebar-reorder only. Distinct `UTType`s keep the three drag kinds unconfusable.
- **A guarded delete already exists.** `deleteAssets` + `MediaReaper`
  (`041`/`042`) do reference-counted orphan handling (blobs → Trash) — the one
  audited data-loss path, reused by undo (7A/16A).

## The core decision: a Space is not a collection

A board holds **placements** (`space_item` rows), not memberships. So an external
import does **two** things: (1) ingest the bytes into the library as a real asset
(home = **Unsorted**), and (2) place that asset on the board at the drop point.
Library-asset drags (already have a home) do only step 2.

18A content-hash dedup means dropping a ref already in the library **reuses the
existing asset** (no duplicate row, no second Unsorted membership) and simply
places it. **Dedup applies to the asset, not to placements** — re-dropping an
on-board asset legitimately adds a *second* tile.

## Architecture (reviewed)

- **1A — Shared import orchestration lives in `IngestionModel`.** Extract
  `dispatch`'s body into `IngestionModel.importInputs(_:into:) async -> [Asset]`;
  `CollectionView` and the canvas both call it. No second ingest path.
- **2A — Explicit return channel.** `importInputs` returns the dedup-resolved
  `[Asset]`; the canvas `await`s it and places the results. There is no
  event/notification bus.
- **3A — One screen→world transform.** Reuse the renderer's existing hit-test
  transform (extract its pure math so hit-test *and* placement share it) — never a
  parallel re-implementation that could drift under pan/zoom.
- **4A — AppKit drop.** `CanvasHostView` becomes an `NSDraggingDestination`
  (`registerForDraggedTypes`: file/image/URL + `AssetDragPayload`'s `UTType`),
  giving the exact `draggingLocation` → world point and clean coexistence with
  canvas gestures (pan/zoom, tile-drag `232`, marquee `233`). Not a SwiftUI overlay.

## Import surfaces

### S1 — External drop onto the canvas (the headline)
Finder files, browser images, dragged web URLs dropped anywhere on the board.
The AppKit destination (4A) decodes providers via `DirectInputReader`, calls
`IngestionModel.importInputs(into: Unsorted)` (1A), `await`s the resolved assets
(2A), and places them at the drop point. Web URLs resolve through the existing
resolver (auth-walled hosts route to the extension exactly as for collections).
**8A — asset-row creation gates placement**: a slow-resolving URL creates its asset
row (possibly media-less per `117-board-media-less-tiles`) → placement happens →
blob/thumbnail fills the tile async. No placeholder placement, no schema change.

### S2 — Library drag onto the canvas (kill the modal detour)
Drag selected asset(s) from the collection grid, search grid, or sidebar onto the
board. The `AssetDragPayload` maps to placement at the drop point — **no re-ingest,
no dedup needed** (the asset already exists). `AddFromLibrarySheet` becomes the
browse/discovery fallback, not the only door.

### S3 — Paste onto the canvas (⌘V)
Clipboard image/URL → the same `DirectInputReader` paste decode, routed through the
AppKit responder chain (mirroring `236`'s Copy so text-field paste stays intact),
placed at the **viewport center** (paste has no cursor point).

### S4 — Direct capture into a space — **out of scope (recorded)**
Captures are async and may arrive with no board open; the capture→Unsorted→drag
path (S2) already covers it. Revisit only if it becomes a real habit.

## Placement + layout (the shared pipeline)

- **6A — One placement pipeline.** Factor a single `place(assets:seededAt:)` that
  owns the insert loop **and** undo registration; both `AddFromLibrarySheet` (seed
  = below content) and import (seed = drop point / viewport center) call it. Refactor
  `SpaceLayout.flowIn` to take an `origin` (the existing `startY`-only call becomes
  `origin: (0, startY)`) — one packing core, not two. New placements get
  `z = maxZ + 1`.
- **13A — Batch the writes.** Add `addAssetsToSpace([placements])` that validates
  the space **once** and inserts all rows in **one** transaction, replacing the
  per-asset `write` loop (`SpaceModel.swift:558`) — kills the N+1 for import *and*
  sheet-add.
- **14A — Reload once per import batch** (not per item); defer incremental append
  until a board is measured large enough to need it.
- **3A — Drop point** comes from the AppKit `draggingLocation` through the reused
  screen→world transform; the block is clamped to `Validation.canvasPlacement`
  bounds rather than throwing near an edge.

## Reporting + undo

- **5A — One reporting vocabulary.** Progress + partial-success/error surface via
  `ToastCenter` + the `238` export-style top-bar progress ring — the board has no
  header, so it reuses the shared surfaces rather than a canvas-only status.
- **7A — Correct inverse per surface.** S2 undo removes the placement only. **S1
  undo removes the placement AND the just-ingested asset when that asset was newly
  created by the import and is referenced nowhere else** — otherwise ⌘Z strands a
  surprise asset in Unsorted.
- **16A — Reuse the audited delete.** S1 undo routes the asset removal through the
  existing `deleteAssets`/`MediaReaper` reference-counted path (batched for the
  import's new assets) — never a bespoke "is this referenced?" query.

## Performance

- **13A** batch transaction (above) — the one real N+1.
- **14A** one reload per batch (above).
- **15A** — Point placement lands tiles **on-screen** (unlike flow-below), so a
  large drop could burst thumbnail decodes. Imported items become ordinary
  `space_item`s and must flow through the existing `DecodeScheduler` + culler — add
  no bespoke throttle; **verify with a 100-image drop** and escalate only if
  measurement shows a spike.
- **16A** batched reference-count check on undo (above).

## Schema / migration impact

**None.** `space_item` placements, `asset`, and Unsorted memberships all exist;
external import reuses the ingest pipeline; placement reuses `addAssetToSpace`.
Zero migration, zero new entity.

## Phased implementation

1. **SP1 (S)** — pure helpers + tests: origin-seeded `flowIn` (6A); extract the
   renderer's screen→world math (3A); extract `canvasDropRoute(...)` (11A). No UI.
2. **SP2 (M)** — **S2 library drag**: `CanvasHostView` `NSDraggingDestination`
   accepting `AssetDragPayload` (4A) → `addAssetsToSpace` at point (13A) via the
   shared pipeline (6A). Highest value-per-effort (no ingest, no dedup).
3. **SP3 (M)** — **S1 external drop**: extract `IngestionModel.importInputs` (1A),
   wire the destination's file/image/URL branch → import into Unsorted → `await`
   resolved assets (2A) → place (8A); `ToastCenter`+ring reporting (5A).
4. **SP4 (S)** — **S3 paste onto canvas** (⌘V → viewport center) via the responder
   chain, mirroring `236`.
5. **SP5 (S)** — undo wiring: S2 placement-only; S1 compound via the shared pipeline
   + `deleteAssets` path (7A/16A).

SP2 and SP3 are independent after SP1; ship SP2 first.

## Test strategy

- **Pure geometry (SP1):** origin-seeded `flowIn` (single = centered on point, N =
  block from origin, `z`-on-top, edge clamp); screen→world round-trip
  (view→world→view identity) across pan/zoom; degenerate viewport / off-canvas point.
- **Pure routing — 11A:** `canvasDropRoute` matrix — `AssetDragPayload` → place;
  external `[.image/.fileURL/.url]` → ingest-then-place; **image+URL together** →
  `DirectInputReader`'s documented precedence; media-less asset → media-less tile;
  empty/foreign payload → reject-no-crash; `SpaceDragPayload`/space-reorder →
  reject; **drop over an existing tile still reaches the canvas** (the `135` lesson).
- **Async orchestration — 10A:** at the `IngestionModel`/`SpaceModel` seam with an
  **injected fake ingest**: success; partial failure (placed count == resolved
  count); slow-resolve (media-less placed, then fills); zero results; **space
  deleted mid-import** (`addAssetToSpace` throws `notFound` → graceful, no crash).
- **Undo — 9A (full matrix):** S1-new (placement + asset removed); S1-that-deduped-
  to-existing (placement only — asset predated the drop); S2 (placement only);
  **shared-reference guard** (asset referenced by another placement/collection
  survives undo); **redo** restores both.
- **Dedup/placement multiplicity — 12A:** already-in-Unsorted file → no second
  membership but a new tile; re-drop on same board → **two** `space_item`s; same
  file twice in one multi-file drop → one asset (placement count per the open
  question); media-less dedup.
- **Perf — 15A:** a 100-image drop measurement pass (decode/memory), not a unit test.
- **AppKit destination glue:** compile-only + manual runbook (the thin executor
  around the pure route).

## Effort: **M total** (S1 + S2 are the substance; S3/S4 small; zero schema)

## Risks & edge cases

- **Drop over an existing tile** must not be captured by a tile's own target and
  lost — fixed *by type* + a host-level catch-all (the `135` lesson, now asserted
  by 11A).
- **Async placement** (S1/8A): place a media-less/pending card immediately for a
  slow URL, never nothing; if resolution ends media-less it stays a media-less tile.
- **Multi-item block near a canvas edge** — clamp to `Validation.canvasPlacement`.
- **Paste ambiguity** (image + URL) — follow `DirectInputReader`'s decision order;
  don't diverge.
- **Dedup surprise** — dedup collapses the *asset*, never board placements; a board
  may repeat a ref.
- **S1 undo data loss** — the reference-count guard (7A/16A) is the guard against
  deleting a shared asset; it is the highest-risk branch and is covered by 9A.

## Settled decisions (reviewed 2026-07-27)

Architecture 1A–4A, code quality 5A–8A, tests 9A–12A, performance 13A–16A, as
enumerated above. Feature scope: S1/S2/S3 in, S4 out. Placement at the drop point;
external imports home to Unsorted. Zero schema.

## Settled product decisions (was: open questions)

1. **Multi-file drop progress → one shared toast.** A single aggregate
   `ToastCenter` progress + the `238` ring, resolving to an honest
   "Imported N · skipped M". No per-file toasts (spam on a large Finder drop);
   mirrors the shipped collection-import path.
2. **Same file twice in one drop → one placement.** Dedup duplicates *within* a
   single drop gesture to one `space_item` (asset-level content dedup already
   collapses the bytes). A *separate* re-drop still yields a second placement — the
   deliberate "I want it twice" path stays intact.
3. **Board→board IS in scope (v1).** A reference can be dragged from one open
   Space onto another. This requires the canvas to become a drag *source* (a
   `space_item` → `AssetDragPayload` drag-out), not just a destination — a new
   surface tracked as **S5** in the plan. The membership-less payload
   (`nilSourceID`) means the destination already treats it as a copy/add (the
   board is always additive), so only the source side is new work.

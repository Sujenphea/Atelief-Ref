# 059 — Import into Spaces: Implementation Plan

> Kind: `plan`. The phased build for [058](./058-spaces-import-overview.md) — drag /
> drop / paste references onto a Space canvas. Every decision (`1A`–`16A`) was
> settled in the 058 design review (Architecture / Code Quality / Tests /
> Performance) and is referenced by tag here. **Zero schema.**

## Locked decisions (from 058)

| Tag | Decision |
|---|---|
| **1A** | Extract `CollectionView.dispatch` body → `IngestionModel.importInputs(_:into:) async -> [Asset]`; one ingest path. |
| **2A** | `importInputs` returns dedup-resolved `[Asset]`; canvas `await`s + places. No event bus. |
| **3A** | Reuse the renderer's hit-test screen→world transform (extract pure math); no parallel impl. |
| **4A** | Canvas drop = `CanvasHostView` `NSDraggingDestination`; not SwiftUI `.onDrop`. |
| **5A** | Progress + partial-failure via `ToastCenter` + the `238` progress ring. |
| **6A** | One `place(assets:seededAt:)` (insert loop + undo); `flowIn` gains `origin`. |
| **7A** | *(revised SP5)* S1 & S2 undo = placement-only; the ingested asset stays in Unsorted — consistent with collection imports, whose ingest isn't undoable either. |
| **8A** | Asset-row creation gates placement; blob/thumbnail fills async (reuse `117`). |
| **9A** | *(revised SP5)* Undo matrix: S1/S2 placement undo→redo. No shared-reference guard — nothing is deleted, so there is no data-loss branch. |
| **10A** | Unit-test ingest→place at the model seam with an injected fake ingest. |
| **11A** | Extract pure `canvasDropRoute(...)` (mirror `DropRouter`) + exhaustive matrix. |
| **12A** | Extend the idempotency suite with board-placement multiplicity cases. |
| **13A** | Batch `addAssetsToSpace([...])` — validate space once, one transaction. |
| **14A** | One board reload per import batch; defer incremental append. |
| **15A** | Reuse `DecodeScheduler`/culler; no bespoke throttle; verify with a 100-drop. |
| **16A** | *(revised SP5 — void)* No asset deletion on undo (placement-only per 7A); `MediaReaper` stays out of the import path entirely. |

## Grounding — reused primitives (do not rebuild)

- `DirectInputReader.inputs(from:into:now:)` (AtelierIngestion) — provider → `[IngestInput]`.
- `CollectionView.dispatch(inputs:webURL:undecoded:)` (`CollectionView.swift:719`) —
  the orchestration to **extract** (1A), not to call from the canvas.
- `IngestionModel.resolveLinkAndIngest` / `ingestRemoteImage` (`:2046`) / `addLink`
  (`:2156`) — async web-URL resolution (8A).
- `AppServices.addAssetToSpace(assetID:to:x:y:w:h:z:)` (`AppServices.swift:1873`) —
  per-row placement; validates `Space.exists` + `Asset.exists` (`:1886`) +
  `Validation.canvasPlacement`. Batch sibling `addAssetsToSpace` is added in P1 (13A).
- `SpaceModel.addAssets` (`SpaceModel.swift:544`) + its `registerReversible(...)` —
  the insert-loop + undo pattern to **factor** into `place(assets:seededAt:)` (6A).
- `SpaceLayout.flowIn(aspects:startY:startZ:)` / `SpaceLayout.aspect` — packing +
  cell sizing; `flowIn` gains `origin` (6A).
- `DropRouter.swift` — the "one pure decision, view executes the outcome" pattern
  `canvasDropRoute` mirrors (11A).
- `AssetDragPayload` (`assetIDs` + `sourceCollectionID`) / `SpaceDragPayload`
  (reject at canvas) — typed drags via distinct `UTType`s.
- `CanvasHostView` — AppKit host (already a responder for `copy(_:)`, `236`); gains
  `NSDraggingDestination` (4A). The renderer's hit-test transform (3A) lives here/in
  the renderer.
- `ToastCenter` + the `238` top-bar progress ring — reporting (5A).
- `deleteAssets` + `MediaReaper` (`041`/`042`) — reference-counted delete for S1
  undo (7A/16A).
- `117-board-media-less-tiles` — media-less tile rendering for pending/auth-walled.

## Current state (baseline)

- `SpaceView` registers no drag types; the only entry is `AddFromLibrarySheet`.
- `addAssetToSpace` is one-row-per-call inside its own transaction; `addAssets`
  loops it and flows **below** content, then `await load()` (full reload).
- `dispatch` is private to `CollectionView` and mutates view-local progress.
- No screen→world helper in `SpaceView`/`CanvasContent`/`SpaceLayout` (it's in the
  renderer/host, used by hit-testing).

---

## Phase SP1 — Pure foundations (S) · no UI

Everything here is host-free and `swift test`-covered before any drag code exists.

1. **Origin-seeded layout (6A).** Refactor `SpaceLayout.flowIn` to
   `flowIn(aspects:origin:startZ:)`; existing callers pass `origin: (0, startY)`.
   Single item → centered on `origin`; N → justified block growing down/right.
2. **Screen→world (3A).** Extract the renderer's hit-test transform into pure math
   `world(fromViewPoint:viewport:)` shared by hit-test **and** placement.
3. **Route decision (11A).** `canvasDropRoute(payload:providers:point:) ->
   CanvasDropOutcome` — the pure `place` / `ingestThenPlace` / `reject` decision,
   mirroring `DropRouter`.

**Tests:** `flowIn` (single/centered, N-block, z-on-top, edge clamp, degenerate
width); `world(fromViewPoint:)` view→world→view identity across pan+zoom, off-canvas
point; `canvasDropRoute` matrix — asset-payload→place, external→ingest, image+URL
precedence, media-less, empty/foreign→reject, `SpaceDragPayload`→reject,
drop-over-tile→canvas.

**Gate:** all pure suites green.

## Phase SP2 — S2 library drag (M) · fastest user-visible win

No ingest, no dedup — pure placement of existing assets.

1. **Batch placement (13A).** `AppServices.addAssetsToSpace(_ placements:[...]) ->
   [SpaceItem]` — validate the space once, insert all rows in one transaction.
2. **Shared pipeline (6A).** `SpaceModel.place(assets:seededAt:)` owns the
   origin-seeded `flowIn` + `addAssetsToSpace` + `registerReversible`; refactor
   `addAssets` to call it with `seededAt: .belowContent`. One reload after the batch
   (14A).
3. **AppKit destination (4A).** `CanvasHostView` `registerForDraggedTypes` for
   `AssetDragPayload`'s `UTType`; `draggingEnded` → `canvasDropRoute` →
   `world(fromViewPoint:)` → `place(assets:seededAt: .point(p))`.
4. **Undo (7A/SP5-early).** S2 registers placement-only reversible (already the
   `addAssets` shape).

**Tests:** `addAssetsToSpace` single-transaction + validate-once (10A-style seam);
place-at-point vs below-content (6A); S2 undo/redo (subset of 9A); drop-over-tile
routes to canvas (11A executor). Manual: drag multi-select grid→board.

**Gate:** library drag places at the cursor; sheet path unchanged (regression suite).

## Phase SP3 — S1 external drop (M)

1. **Extract orchestration (1A/2A).** `IngestionModel.importInputs(_ inputs:into:)
   async -> [Asset]` — lift `dispatch`'s body; return dedup-resolved assets;
   `CollectionView.dispatch` becomes a thin wrapper (its progress state stays local).
2. **Wire the file/image/URL branch (4A/8A).** Destination decodes via
   `DirectInputReader` → `importInputs(into: Unsorted)` → `await` assets → `place`
   at the recorded drop point. Slow URLs: asset row (maybe media-less) gates
   placement; blob fills the tile async (`117`).
3. **Reporting (5A).** `ToastCenter` partial-success + the `238` progress ring on
   the board; honest N-imported / M-skipped.

**Tests (10A, injected fake ingest):** success; partial failure (placed ==
resolved); slow-resolve → media-less then fills; zero results; **space deleted
mid-import** → `notFound` handled, no crash, no dead-board placement. Dedup/board
multiplicity (12A): already-in-Unsorted → new tile no new membership; re-drop →
two `space_item`s; same file twice in a drop → one asset. Manual: Finder/browser
drop.

**Gate:** external drop imports to Unsorted AND places; no second ingest path
(assert `CollectionView` delegates to `importInputs`).

## Phase SP4 — S3 paste (S)

⌘V on the canvas via the AppKit responder chain (mirror `236` so text-field paste
is untouched) → `DirectInputReader` paste decode → `importInputs` → place at
**viewport center**. Tests: paste image / paste URL / paste with no importable
content → no-op; center placement.

## Phase SP5 — Undo completion (S) · *revised: placement-only*

**Decision revised (SP5).** Undo for BOTH surfaces is placement-only — it removes
the board tile(s), and the ingested asset stays in Unsorted. Two findings drove
this away from the original compound-delete plan:

1. An external drop ingests into **Unsorted** (a real membership) *plus* the board
   placement, so the asset is never truly "unreferenced".
2. **Collection imports aren't undoable at all** — the grid's `run()` registers no
   undo; ⌘Z reverses delete / remove / move / reorder / rename, never an *import*.
   Deleting the asset on a board-import undo would make the board inconsistent with
   every other import surface.

So there is no asset deletion, no `MediaReaper` in the import path, and no
shared-reference guard (nothing is deleted → no data-loss branch). The placement
undo/redo already registered by `insertPlaced` (SP2) IS the S1 inverse too.

SP5 is therefore **verification + hardening**, not new machinery: prove the S1
external-drop undo removes only the placement, leaves the asset in Unsorted, and
redoes cleanly.

**Tests:** S1 import → undo (tile gone, asset + its Unsorted membership survive) →
redo (tile back, stable id). Plus the existing S2 undo/redo.

**Gate:** the S1 undo→redo matrix green; the imported asset provably survives undo.

## Phase SP6 — Perf verification (S, measurement)

15A: seed a board, perform a **100-image drop** at a point, measure decode/memory;
confirm imported tiles flow through `DecodeScheduler` + culler. No bespoke throttle
unless the measurement shows a spike (then escalate, documented).

---

## Sequencing & effort

SP1 → SP2 (ship for the win) → SP3 → SP4 → SP5 → SP6. SP2/SP3 independent after
SP1. **Effort: M total** (SP2+SP3 substance; SP4/SP5 small; SP1 pure/cheap; zero
schema).

## Risks (build-time)

- Extracting `importInputs` touches the shipped collection path — lean on its
  existing tests; land 1A behind the unchanged `dispatch` wrapper first, then wire
  the canvas.
- Extracting the renderer transform (3A) must keep hit-testing byte-identical —
  add the view→world→view identity test *before* refactoring.
- AppKit `NSDraggingDestination` coexistence with pan/zoom/tile-drag/marquee — the
  reason for 4A; validate the drop-over-tile case early (11A executor).

## Settled product decisions (was: open questions)

1. **Multi-file drop progress → one shared toast** (aggregate `ToastCenter` +
   `238` ring, "Imported N · skipped M"). Wired in SP3.
2. **Same file twice in one drop → one placement.** SP3 dedups duplicate resolved
   assets *within* a batch before placing; a separate re-drop still adds a second
   `space_item` (already covered by SP2's `dropSameAssetTwice`).
3. **Board→board IS in v1** — see new phase **SP7** below (canvas drag-*source*).

## Phase SP7 — Board→board drag-out (M) · the canvas as a drag SOURCE

Boards open one at a time, so board→board happens by dragging a canvas tile onto a
**sidebar space row** — which already accepts a membership-less `AssetDragPayload`
and calls `addAssetsToSpace` (SP2 destination + the shipped sidebar drop). So SP7 is
purely the SOURCE half: an ⌥-drag on a tile starts an `NSDraggingSession` writing an
`AssetDragPayload` (assetIDs of the dragged tiles, `sourceCollectionID = nilSourceID`)
so a sidebar space / collection row ADDS a copy — never moves — the reference.

1. **Trigger revised: ⌥-drag, not leave-bounds.** The original plan started a
   session when a tile drag *left the view bounds*. Implementation showed that's
   jarring — the tile follows the cursor as an in-view move, then must **snap back**
   to origin when the cursor crosses the edge (board→board is additive, so the
   source stays). ⌥-drag avoids it entirely: with ⌥ held, the tile drag is a
   drag-out session **from the start** (no in-view move → no snap-back), and ⌥=copy
   matches the additive semantics. Plain drag still moves in-view (no regression).
2. **Payload source (app side).** `CanvasHostView.onBeginTileDragOut(Set<Int>) ->
   NSPasteboardItem?`: the app maps tile ids → asset ids and returns an
   `AssetDragPayload` pasteboard item (nil source). Package stays payload-agnostic
   (same layering as the drop seam). `SpaceContent.dragOutPayload(forTileIDs:)` is
   the pure, tested mapping (z-ordered, elements skipped).
3. **Self-drop guard.** `CanvasHostView` is now an `NSDraggingSource`; while it owns
   an active drag-out session (`isActiveDragSource`) it refuses drops back onto
   itself, so a drag-out dropped on the SAME board can't duplicate in place.
4. **Undo.** Board→board is additive on the destination (a normal S2 placement +
   undo via the sidebar path); the source board is untouched (a copy) — no
   cross-board compound undo.

**Tests:** `dragOutPayload` carries the right asset ids + nil source, z-ordered,
elements skipped, nil when no asset tiles. (The AppKit session / self-drop / drag
image are manual-runbook — they need a live drag.)

**Gate:** ⌥-dragging a board tile onto a sidebar space row adds it there, the source
board unchanged; a plain drag still just moves the tile in place.

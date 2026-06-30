# 005 — Canvas: Spike verdict (overview)

> Outcome of the Phase 1 canvas rendering spike — the project's #1 critical-path
> risk. Builds on the [foundation plan](./004-foundation-plan.md) (build-order
> step 1). Implementation lives in the local `CanvasRenderer` Swift Package;
> per-checkpoint detail is in `.change-log/001`–`006`.

## The question the spike had to answer

The infinite canvas has no off-the-shelf native equivalent, so the foundation
docs flagged one decisive risk: **is Core Animation (CALayer tiling) fast enough
to render thousands of tiles at 120fps, or must we invest weeks in a Metal
renderer before building the app around it?** (Decision **A1**: build CA-first,
let a benchmark decide.)

## Verdict: **Core Animation is sufficient for the MVP. Metal is deferred.**

At the agreed **P13 target** — ~5,000 dummy tiles, 1440×900 viewport, realistic
clustered layout with real decoded thumbnails — the benchmark measured:

| Metric | Result | Bar | Outcome |
| --- | --- | --- | --- |
| Realized tiles (one frame) | ~2,069 | — | heavy, realistic |
| Per-frame cull + layer sync (main thread) | **~4.6 ms** | ≤ 8.33 ms (120fps) | **pass, ~45% headroom** |
| Resident thumbnail cache | ~1 MB | bounded by ceiling | pass |
| Process memory peak | ~38 MB | scales with *visible* set | pass |

*(Measured on the dev machine via `swift test --filter CanvasBenchmark`. Numbers
vary by hardware; the hard gate is the per-frame budget assertion, kept as a CI
regression guardrail — decision T10.)*

**Conclusion:** the CA-first approach clears the 120fps budget with headroom at
MVP scale, so we proceed on Core Animation and do **not** build the Metal
renderer now. This banks the weeks Metal would have cost and keeps the codebase
smaller — the "engineered enough" call.

## What the spike built (reused at build-order step 5)

- **Pure logic** (headless, fully tested): `CanvasTransform` (single world↔screen
  owner), `TileCuller`, `LODPolicy` (hysteresis), `Tile` (mirrors
  `canvas_x/y/w/h/z`).
- **The one stable seam**: `TileProvider` — step 5 swaps the dummy generator for
  a `CollectionItem`-backed provider with no renderer change.
- **CA host**: `CanvasEngine` (cull → recycle → LOD → paint), `LayerPool`
  (recycling), `ThumbnailCache` (LRU + memory ceiling), `DecodeScheduler`
  (off-main decode + prefetch + cancel), `CanvasHostView`/`CanvasView`.
- **Guardrails**: 66 Swift Testing cases + layer-pool invariants + the perf
  benchmark.

## Caveats / where this verdict could change

- The benchmark measures **main-thread CPU cost** (cull + layer sync), the right
  proxy for a headless CI gate. True on-screen fps and GPU compositing cost are a
  **manual Instruments** check (Core Animation + Allocations), still recommended
  before shipping.
- Headroom is ~45% at ~2k realized tiles. If real boards routinely realize many
  more simultaneously-visible tiles (e.g. 10k+), or full-res LOD dominates,
  re-run the benchmark — that's the trigger to revisit.
- Per-site/real-data costs (variable image sizes, full-res decode under fast
  zoom) arrive at step 5; the cache + prefetch + cancellation are in place for
  them, but should be re-profiled with real assets.

## Documented Metal fallback (only if a future benchmark regresses)

Kept brief so escalation isn't a cold start (decision A1):

- **Renderer swap, seam preserved.** Replace the `CanvasEngine` layer-sync with a
  single `MTKView`; keep `TileProvider`, `CanvasTransform`, `TileCuller`,
  `LODPolicy` unchanged (they're render-backend-agnostic).
- **Texture atlas** of decoded thumbnails per LOD tier; `ThumbnailCache` becomes
  an atlas allocator (same LRU + ceiling discipline).
- **Instanced quad draw**: one instanced draw call over visible tiles; the
  `CanvasTransform` becomes the projection matrix; `z` → draw order / depth.
- **Hit-testing** moves from AppKit layer hit-tests to a `screenToWorld` +
  `TileCuller` point query (already pure, already tested).
- Re-use the existing benchmark as the before/after gate.

## Status

Phase 1 (canvas spike) is **complete and de-risked**. The renderer, its seam, and
its benchmark are ready for build-order step 2 (data core) and step 5
(productionize the canvas against real data).

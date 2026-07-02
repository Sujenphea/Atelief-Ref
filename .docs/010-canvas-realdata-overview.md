# 010 — Canvas on real data: Overview (decisions + notes)

> Build-order **#5** — productionize the Phase-1 canvas spike
> ([005](./005-canvas-overview.md)) against real library data. The spike proved
> Core Animation is fast enough and left two seams for exactly this step; this
> doc records how the app plugs into them. Builds on the data core
> ([006](./006-datacore-overview.md)), ingestion ([007](./007-ingestion-overview.md)),
> and folders ([008](./008-folders-overview.md)).

## What we built

The Canvas tab now renders the **selected folder's real images** on the infinite
canvas — pan/zoom, viewport culling, and LOD all inherited unchanged from the
spike. No renderer rewrite: we swapped the spike's dummy data sources for
real-data ones through the seams the spike deliberately exposed (decision A2).

## Decisions

- **C1 — Second seam: `TileImageSource`.** The spike's `TileProvider` (tile
  *geometry*) was already a protocol; image *content* was hard-wired to the
  concrete `FixtureImageSet`. We introduced `TileImageSource`
  (`imageKey(for:)` + `imageData(for:tier:)`) so `CanvasEngine` no longer depends
  on the fixture type. `FixtureImageSet` conforms (spike/benchmark/tests
  unchanged — behaviour-preserving); the app implements it over real assets.
- **C2 — `CanvasContent` is the real-data provider.** One app-side object
  conforms to **both** seams over a `[CollectionItemDetail]` + `MediaStore`:
  tiles from the items, thumbnails from disk. `Tile.id` = the item's index (so it
  indexes straight back to its detail).
- **C3 — Justified-rows auto-layout.** Imports don't set canvas placement, so
  items flow into a Pinterest-style justified gallery sized by each image's
  aspect ratio (fixed row height, wrap at a max row width). An item **with**
  explicit `canvas_x/y/w/h` keeps it. Persisting a user-arranged layout is later
  canvas-editor work (Phase 4).
- **C4 — LOD tier ↔ thumbnail tier line up exactly.** The renderer's LOD pixel
  sizes (128/512/1280) are the ingest thumbnail tiers (small/medium/large), so
  `imageData` returns the **pre-generated** thumbnail for the tier — no
  re-scaling, and a far cheaper decode than the spike's downsample-from-source.
- **C5 — Per-blob-hash cache key (dedup).** `imageKey` is a dense index per
  distinct blob hash, so multiple tiles of the same image — or content-identical
  assets — share one decode and one cached bitmap per tier.
- **C6 — One shared model across both tabs.** `IngestionModel` is lifted to
  `ContentView` and shared by Library + Canvas, so both show the same selected
  folder (pick in Library → see on Canvas) over **one** database connection. The
  canvas rebuilds (SwiftUI `.id(contentsVersion)`) when the folder's contents
  change; content is cached per version so `body` re-evaluation is cheap.
- **C7 — Dropped the dummy spike tab.** The app's Canvas tab shows real data now;
  the dummy generator + fixtures live on in the package for the tests, benchmark,
  and preview harness.

## Caveats / follow-ups

- **Thumbnail file reads happen on the main thread** (in `imageData`, before the
  off-main decode). Thumbnails are small pre-sized JPEGs, but this is the exact
  "re-profile with real assets" trigger 005 flagged. If panning janks, the fix is
  a localized one: hand `DecodeScheduler` a `@Sendable () -> Data?` so the read
  moves off-main too. **Not done yet — profile first (Instruments).**
- **No canvas editing / placement persistence.** You can view a board, not
  rearrange it. Drag-to-place + writing `canvas_*` back through App Services is a
  later step.
- **Rebuild resets pan/zoom.** Importing into the open folder rebuilds the host,
  which reframes to fit. Fine for MVP; incremental tile updates are a later
  refinement.
- **SwiftUI/host wiring is compile-verified only** — no runtime GUI test. A
  manual pan/zoom over a real folder is pending.

## Verification

- `swift test` (CanvasRenderer): **67 tests green**, incl. the `measure {}`
  benchmark — the seam refactor is behaviour-preserving.
- `xcodebuild -scheme AtelierRefs`: **BUILD SUCCEEDED** (no Sendable warnings).

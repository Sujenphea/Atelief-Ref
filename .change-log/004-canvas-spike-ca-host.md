# 004 — Canvas spike: Core Animation host

**Checkpoint 4** of the Phase 1 canvas rendering spike.

## Summary

Built the side-effecting Core Animation layer (decision **C5**: the AppKit/CA
host, separate from the pure logic) and wired a live harness into the app. The
canvas now culls, recycles layers, caches decoded thumbnails, and decodes
off-thread with a prefetch ring — the full CA-first rendering loop (decision A1).

## Decisions realized

- **A1** — CALayer recycling + LOD rendering loop.
- **P14** — `ThumbnailCache`: LRU, `(imageID, tier)` keyed, hard resident-memory
  ceiling, evict-with-protected-key. Kills re-decode thrash on pan.
- **P15** — `DecodeScheduler`: off-main decode (concurrent `DispatchQueue`) +
  main-actor delivery; `retainOnly` cancels stale decodes; `prefetchMarginScreen`
  ring decodes just-offscreen tiles ahead.
- **P16** — `CanvasEngine` selects per-tile LOD from on-screen size with
  hysteresis; tier→pixel-size mapping (128/512/1280) feeds the downsample.
- **C5** — `CanvasEngine` is window-free (headless-testable / benchmarkable);
  `CanvasHostView` is a thin `NSView` owning events only.

## Concurrency notes (Swift 6)

- `SendableImage` (`@unchecked Sendable`) explicitly transfers an immutable,
  read-only `CGImage` from the decode queue to the main actor.
- `LayerPool.make` is `@MainActor`; `DecodeScheduler.decodeQueue` is
  `nonisolated` (a `Sendable` `DispatchQueue`).

## Files changed

- `Sources/CanvasRenderer/Host/SendableImage.swift` *(new)*
- `Sources/CanvasRenderer/Host/LayerPool.swift` *(new)* — recycle pool;
  `inUseCount` / `allocatedCount` for the CP5 invariants.
- `Sources/CanvasRenderer/Host/ThumbnailCache.swift` *(new)* — LRU + ceiling.
- `Sources/CanvasRenderer/Host/DecodeScheduler.swift` *(new)* — async/blocking
  decode, downsample via `CGImageSourceCreateThumbnailAtIndex`, cancellation.
- `Sources/CanvasRenderer/Host/CanvasEngine.swift` *(new)* — the per-frame
  `sync()`: cull → recycle → place → LOD → paint/request; `warmVisibleBlocking`
  for benchmark warming; introspection counters.
- `Sources/CanvasRenderer/Host/CanvasHostView.swift` *(new)* — `NSView` host;
  scroll = pan, pinch = zoom, layout/resize = re-sync.
- `Sources/CanvasRenderer/Host/CanvasView.swift` *(new)* — SwiftUI wrapper.
- `Tests/CanvasRendererTests/HostTests.swift` *(new)* — 12 tests: pool reuse/
  detach, cache round-trip/LRU/touch/oversized, decode downsample/async/cancel,
  engine layer-per-visible-tile / pan-away-recycle / zero-viewport.
- `AtelierRefs/AtelierRefs/ContentView.swift` *(modified)* — live spike harness:
  `CanvasView` over ~5,000 dummy tiles.

## Verification

- `swift test` — **62 tests in 13 suites passed**.
- `xcodebuild build -scheme AtelierRefs` — **BUILD SUCCEEDED** (app embeds the
  canvas, exercising the CP1 package wiring with real usage).
- Manual: run AtelierRefs → scroll pans, pinch zooms a ~5k-tile board.

## Migration notes

None — additive. `CanvasEngine`/`CanvasHostView` stay; at step 5 the
`DummyTileProvider` + `FixtureImageSet` are swapped for real data behind the same
`TileProvider` seam.

# 005 — Canvas spike: layer-pool invariant tests

**Checkpoint 5** of the Phase 1 canvas rendering spike.

## Summary

Added the rigorous layer-pool invariant suite (decision **T11**): scripted
pan / zoom / resize sequences that assert the recycling invariants at **every**
step. These catch the leaked- or over-allocated-layer bugs that would otherwise
silently inflate the memory profile the spike exists to prove.

## Invariants asserted (per step)

1. **realized == visible** — `activeLayerCount` equals the culled visible tile
   count.
2. **no orphans** — `rootLayer.sublayers.count` equals `activeLayerCount` (every
   recycled layer was detached).
3. **bounded, no leak** — `allocatedLayerCount` equals the *running peak* visible
   count: idle layers are parked for reuse, never leaked or grown past the peak.

## Decisions realized

- **T11** — layer-pool invariants under scripted camera motion (full XCUITest
  gesture automation remains deferred to step 5+, as planned).

## Files changed

- `Tests/CanvasRendererTests/EngineInvariantTests.swift` *(new)* — 4 tests:
  - pan(×8) → zoom-in → zoom-out → resize-up → resize-down, invariants each step;
  - 20 oscillating round-trip pans (proves allocated never climbs past peak);
  - return-to-start transform reproduces the exact visible set;
  - a prefetch margin realizes strictly more tiles than no margin.
  - The test camera starts zoomed out and centred on the clustered content so the
    invariants compare real (hundreds-of-tiles) sets, not `0 == 0`.

## Verification

`swift test` — **66 tests in 14 suites passed**. The `allocated == peak` check
holding across ~40 camera mutations is the concrete evidence of no per-pan leak.

## Migration notes

None — tests only.

# 002 — Canvas spike: pure logic types + tests

**Checkpoint 2** of the Phase 1 canvas rendering spike.

## Summary

Added the renderer's pure-logic layer (decision **C5** — no AppKit import,
headlessly testable) and a comprehensive Swift Testing suite (decision **T9**).
These are the parts most likely to harbour bugs and the cheapest to test, so they
land first and fully covered.

## Decisions realized

- **C5** — pure value types, separable from the (later) AppKit/CA host.
- **C6** — `CanvasTransform` is the single owner of world↔screen math; culling,
  render, and hit-test will all route through it.
- **A4** — `Tile` mirrors `canvas_x/y/w/h/z` exactly.
- **A2** — `TileProvider` is the one stable seam (geometry now; image access
  added in CP4).
- **C7** — degenerate/non-finite tiles, zoom clamping, and a divide-by-zero guard
  are handled and tested.
- **P16** — `LODPolicy` selects tiers from on-screen size with hysteresis bands.
- **T9** — property-based round-trips + parameterized boundary cases.

## Files changed

- `Sources/CanvasRenderer/CanvasTransform.swift` *(new)* — uniform-scale affine
  `world↔screen`, `visibleWorldRect`, `panned`/`zoomed` (anchor-preserving),
  scale clamped to `[minScale, maxScale]` with `minScale > 0`.
- `Sources/CanvasRenderer/Tile.swift` *(new)* — world-space tile mirroring the
  canvas placement columns; `worldFrame`, `longestWorldEdge`, `isDegenerate`.
- `Sources/CanvasRenderer/TileProvider.swift` *(new)* — the geometry seam.
- `Sources/CanvasRenderer/TileCuller.swift` *(new)* — O(n) viewport intersection
  with a prefetch `margin`, draw-order sort, edge-case rules.
- `Sources/CanvasRenderer/LODPolicy.swift` *(new)* — `LODTier` + hysteresis-aware
  tier selection.
- `Tests/CanvasRendererTests/{TestSupport,CanvasTransformTests,TileTests,TileCullerTests,LODPolicyTests}.swift`
  *(new)* — 35 tests covering round-trips (incl. 1e7 large-coordinate
  precision), zoom-anchor invariance + clamping, culler boundary/touch/contain/
  degenerate/draw-order/margin cases over a known grid, and LOD dead-band /
  no-thrash behaviour.

## Verification

`swift test` — **36 tests in 5 suites passed** (35 new + the CP1 smoke test).

## Migration notes

None — additive, pure types. `TileProvider` will gain an image-source accessor
in Checkpoint 4; the geometry contract here is stable.

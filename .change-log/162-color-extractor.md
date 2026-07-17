# 162 — Imaging: dominant-color extraction (Lab k-means)

## Summary

Second pure primitive for feature 012: reduce an image to its top-N dominant
colors as `[hex, coverage]` — the data behind 012's detail swatch row and the
search-by-color filter. Clustering runs in perceptually-uniform CIE **Lab**, so
swatches group the way the eye does (near-identical blues merge; a small saturated
accent survives) rather than by raw sRGB distance.

Pure core + thin adapters, matching the imaging layer:

- `swatches(fromPixels:maxColors:)` — deterministic weighted k-means: quantize
  pixels into a weighted histogram, seed clusters farthest-first over a canonical
  ordering (no RNG), run weighted Lloyd iterations in Lab, emit each cluster as its
  members' weighted-mean sRGB (always in-gamut — no Lab→sRGB inverse) with
  fractional coverage, sorted most-dominant first. Determinism is a tested contract
  (order-independent under shuffle), per the 012 test strategy.
- `srgbToLab` — the standard sRGB→linear→XYZ→Lab (D65) conversion, pinned against
  published Lab values in tests.
- `swatches(fromCGImage:maxColors:)` / `extract(from:maxColors:)` — decode via the
  shared `ImageDecoding` helper (160). The `CGImage` seam lets the future analyzer
  decode an asset once and run both this and the perceptual hash (161) over it.
  Near-transparent pixels are dropped so a cutout's background can't dominate.

**Persistence note:** returns typed `[ColorSwatch]`; serializing to 012's
`asset_analysis.colors TEXT` JSON is the analyzer's job at the AtelierCore seam —
this package never touches GRDB or JSON encoding.

Review decisions folded in (from this session's review): one shared `accumulate`
step for the Lloyd-recompute and final build (no duplicated summation); one shared
`finalize` for the few-colors and clustered paths; in-place histogram mutation;
named `alphaThreshold`; and a documented work bound on the clustering loop.

## Files changed

### AtelierIngestion
- `Imaging/ColorExtractor.swift` (new) — Lab k-means dominant-color extraction +
  CGImage/byte adapters.

### AtelierIngestionTests
- `ColorExtractorTests.swift` (new) — 16 tests: Lab anchors (black/white/primaries)
  + gray monotonicity; pure behavior (solid, 50/50, 70/30 ordering, fewer/more
  colors than clusters, coverage sums); determinism under shuffle; randomized
  invariants (count ≤ max, coverage ≤ 1, deterministic); and adapters (solid PNG,
  CGImage seam, two-tone, transparent→[], degenerate → typed errors).
- `TestSupport/FixtureImages.swift` — new `twoToneImage(...)` and
  `transparentImage(...)` builders.

## Migration notes

None. Pure additive utility + tests; no schema, no wiring. Full AtelierIngestion
suite green (163 tests). Analyzer wiring (`asset_analysis`, backfill queue, Vision
seam for OCR/suggested-tags) lands in a later 012 phase.

## Verify

- `swift test --filter ColorExtractor` — 16 tests green.
- `swift test` (AtelierIngestion) — 163 tests green.

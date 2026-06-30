# 003 — Canvas spike: deterministic seeded data + fixtures

**Checkpoint 3** of the Phase 1 canvas rendering spike.

## Summary

Added the spike's reproducible workload (decision **T12**): a seeded PRNG, a
clustered/varied tile generator, the concrete dummy ``TileProvider``, and a
procedurally-generated set of real source images (decision **C8**) for the decode
pipeline that lands in Checkpoint 4.

Everything is byte-for-byte reproducible from a seed, so the Checkpoint 6
benchmark can detect regressions and the culling tests can assert exact sets.

## Decisions realized

- **T12** — `SeededRandom` (SplitMix64) drives deterministic tile layout and
  image bytes.
- **C8** — fixtures are *real* decoded bitmaps (gradient + scattered shapes),
  varied in size/aspect, not solid colours — so decode/downsample/upload cost is
  realistic.
- **A2** — `DummyTileProvider` is the concrete implementation of the seam.

## Notable decision: PNG, not JPEG, for fixtures

ImageIO's **JPEG** entropy-coding is not byte-deterministic across runs (observed
~1% size jitter on one of six images), which broke the T12 determinism test.
Switched to lossless **PNG**: encoding is deterministic, and the costs the spike
actually measures (decode, downsample, texture upload, resident memory) are
format-independent. Source *bitmaps* were already deterministic; only the JPEG
encoder was not.

## Files changed

- `Sources/CanvasRenderer/Spike/SeededRandom.swift` *(new)* — SplitMix64 RNG.
- `Sources/CanvasRenderer/Spike/DummyTileGenerator.swift` *(new)* — `Config`
  (default ~5,000 tiles, 40 clusters), gaussian-clustered placement, varied
  size/aspect, unique `id`/`z`, guaranteed non-degenerate.
- `Sources/CanvasRenderer/Spike/DummyTileProvider.swift` *(new)* — `TileProvider`
  over generated tiles.
- `Sources/CanvasRenderer/Spike/FixtureImages.swift` *(new)* — `FixtureImageSet`:
  N deterministic PNG-encoded source images; `data(forTileID:)` maps tiles →
  images by modulo (negative-safe).
- `Tests/CanvasRendererTests/SpikeDataTests.swift` *(new)* — 14 tests: RNG
  determinism, generator count/determinism/uniqueness/bounds, provider parity,
  fixture determinism + decodability + id-wrap.

## Verification

`swift test` — **50 tests in 9 suites passed**.

## Migration notes

None — additive spike scaffolding under `Sources/CanvasRenderer/Spike/`. Replaced
by real `CollectionItem`-backed data at build-order step 5.

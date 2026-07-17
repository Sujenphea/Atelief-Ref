# 161 — Imaging: perceptual (difference) hash for near-duplicates

## Summary

First pure primitive for feature 012 (on-device intelligence): a 64-bit **dHash**
plus its Hamming-distance metric — the signature the planned "Duplicates" review
surface (012 I5) compares. Where `ContentHasher` (SHA-256) is byte-exact and misses
a resized/re-encoded copy, dHash is content-shaped: it survives resize and
re-encode, so visually-equal images land at a small Hamming distance.

Structured as a pure core + thin adapters, matching the rest of the imaging layer:

- `dHash(reducedLuminance:)` — total, framework-free algorithm over an already
  reduced 9×8 luminance grid; bits packed MSB-first. Its 72-sample contract is a
  `precondition` (a call-site programmer error, never data-driven), so the pure
  core throws nothing and is exhaustively grid-testable.
- `hammingDistance(_:_:)` — `nonzeroBitCount` of the XOR; reflexive + symmetric.
- `hash(_ cgImage:)` / `hash(from: Data)` — the only CoreGraphics/ImageIO parts.
  The `CGImage` entry lets the future `AssetAnalyzer` decode an asset **once** (via
  the shared `ImageDecoding` helper, 160) and run both this and the upcoming color
  extractor over the same image instead of decoding twice.

**Known limitation, documented in-file (inherent to dHash, not a bug):** the hash
is luminance-only, so every solid/flat image collides at distance 0 and equal
-brightness color swaps hash identically. The policy for those blind spots belongs
in the I5 duplicates surface (disambiguate distance-0 clusters with the color
signature), not in the primitive.

**Persistence note:** `hash` returns `UInt64` (a bit-signature is unsigned and
Hamming must see raw bits). The `UInt64`↔`Int64` reinterpretation for 012's
`asset_analysis.phash INTEGER` column is the analyzer's job at the AtelierCore
seam — it never happens in this package, keeping signedness/GRDB out of the hash.

## Files changed

### AtelierIngestion
- `Imaging/PerceptualHash.swift` (new) — dHash + Hamming + CGImage/byte adapters.

### AtelierIngestionTests
- `PerceptualHashTests.swift` (new) — 14 tests: known grid→hash, MSB-first bit
  ordering, strict comparison, Hamming algebra + single-bit-flip, randomized metric
  invariants (reflexive/symmetric/bounded/stable), and adapter stability (resize,
  PNG↔JPEG re-encode) + degenerate-input smoke over lossless fixtures.
- `TestSupport/FixtureImages.swift` — new `solidColorImage(...)` (a genuinely flat
  color, vs the existing gradient `solidImage`) and a `makeFilledCGImage(...)`
  primitive.

## Migration notes

None. Pure additive utility + tests; no schema, no wiring, no change to existing
callers. Analyzer wiring (`asset_analysis` table, backfill queue, Vision seam)
lands in a later 012 phase.

## Verify

- `swift test --filter PerceptualHash` — 14 tests green.

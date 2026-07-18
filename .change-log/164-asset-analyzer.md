# 164 — Analysis: AssetAnalyzer + Vision OCR seam

## Summary

Phase B of feature 012: the service that turns an image into the derived metadata
Phase A's `asset_analysis` stores. Composes the pure imaging cores (perceptual
hash 161, color extraction 162) with an injectable OCR seam.

- **`AssetAnalyzer`** — decodes the source **once** (the 15A benefit) and runs all
  three analyses over the same `CGImage`. The single decode is sized for OCR (the
  largest consumer, and 012's highest search-quality win); hash and color
  downsample from it internally. `analyze(cgImage:)` lets a caller supply an
  already-decoded image (e.g. a stored thumbnail — the deferred 16A optimization),
  skipping the decode. Empty OCR normalizes to `nil`.
- **`TextRecognizing`** — the injectable OCR protocol. Synchronous (Vision's
  `perform` is synchronous, and a sync signature avoids passing a non-`Sendable`
  `CGImage` across an async boundary), so all analysis logic is testable with a
  fake recognizer and no Vision at all.
- **`VisionTextRecognizer`** — the thin production adapter over
  `VNRecognizeTextRequest` (the repo's first Vision use; a system framework,
  imported directly like ImageIO/AVFoundation).
- **`AnalysisResult`** + serialization (the 2A boundary): `signedPHash`
  (`UInt64`→`Int64` bit-cast for `phash INTEGER`) and `colorsJSON`
  (`[{"hex","coverage"}]` for `colors TEXT`, `nil` when empty). `ColorSwatch` is
  now `Codable`, with `encodeList`/`decodeList` owning the JSON shape in Ingestion.

The analyzer produces typed values only; persisting them through
`AppServices.upsertAnalysis` is Phase C. It never touches AtelierCore, so it stays
`swift test`-able with no database.

## Files changed

### AtelierIngestion
- `Analysis/AssetAnalyzer.swift` (new) — `AnalysisResult`, `TextRecognizing`,
  `AssetAnalyzer` (decode-once, hash + color + OCR, serialization).
- `Analysis/VisionTextRecognizer.swift` (new) — the Vision OCR adapter.
- `Imaging/ColorExtractor.swift` — `ColorSwatch: Codable` + `encodeList` /
  `decodeList` JSON codec.

### AtelierIngestionTests
- `AssetAnalyzerTests.swift` (new) — composition (hash/color/OCR wiring, empty-OCR
  normalization, error propagation) and serialization (signed-phash bit-cast,
  colors JSON round-trip, empty→nil) with a fake recognizer.
- `VisionTextRecognizerTests.swift` (new) — guarded OCR smoke test (rendered text
  recognized; blank image → nil).

## Migration notes

None. Pure additive service + tests; no schema, no wiring. Full AtelierIngestion
suite green (175 tests). Backfill orchestration (persisting results via
`upsertAnalysis` over `assetsNeedingAnalysis`) lands in Phase C.

## Verify

- `swift test` (AtelierIngestion) — 175 tests green.

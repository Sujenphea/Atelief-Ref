# 160 — Imaging: shared thumbnail-decode helper

## Summary

Groundwork for feature 012 (on-device intelligence). Two new byte-consuming image
utilities are landing — perceptual hashing and color extraction — and both need
the same `CGImageSource` → `CGImageSourceCreateThumbnailAtIndex` decode that
`ThumbnailGenerator` already does. Rather than let that dance be copy-pasted three
times (and drift), it now lives in one place.

**Change.** New `ImageDecoding.thumbnailCGImage(from:maxPixelSize:)` owns the
source-creation + thumbnail-decode (always-synthesize, EXIF-transform applied) and
its error mapping — `unreadable` for empty/non-image bytes, `decodeFailed` for a
recognized-but-undecodable source. `ThumbnailGenerator.makeThumbnail` now calls it
and keeps only its JPEG re-encode step. Behavior is unchanged; the existing
`ThumbnailGenerator` suite passes untouched.

This is a pure refactor with no functional change — it exists so the 012 utilities
can decode once, consistently, through the same seam.

## Files changed

### AtelierIngestion
- `Imaging/ImageDecoding.swift` (new) — shared `thumbnailCGImage(from:maxPixelSize:)`;
  the single decode + error mapping for every image utility.
- `Imaging/ThumbnailTier.swift` — `ThumbnailGenerator.makeThumbnail` delegates the
  source+thumbnail decode to `ImageDecoding`; retains its JPEG encode.

## Migration notes

None. No schema, no API change to existing callers.

## Verify

- `swift test --filter ThumbnailGenerator` — all 5 tests green (zero-bytes →
  unreadable, corrupt → throws, EXIF transform applied, tier bounds).

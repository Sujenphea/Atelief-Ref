# 034 — Ingestion: real video support in the pipeline (video capture, checkpoint C)

## Finding that reshaped the checkpoint
The plan assumed the pipeline already ingested video (it has a `.video`
`AssetKind` and `classify` maps `.movie`). **It did not.** `ImageMetadata.extract`
opens bytes with `CGImageSourceCreateWithData`, which cannot read a movie
container — an MP4 yields a source whose `CGImageSourceGetType` is **nil**, so
`extract` throws `.unreadable` and never reaches the `.movie` branch (verified with
a probe). So video needs a real AVFoundation metadata AND poster path, not just a
display affordance. Both were added here.

## What changed
- **`MediaProbe`** (new): cheap byte sniff — `looksLikeMovie` (ISO BMFF `ftyp`
  movie brands / QuickTime atoms; image `ftyp` brands like HEIC/AVIF are
  excluded) and `movieContainer` → canonical `video/mp4`/`mov` MIME + extension.
- **`ImageMetadata.videoMetadata(from:)`** (new, async): AVFoundation reads the
  video track's `naturalSize × preferredTransform` (display-oriented dims) +
  `duration`. Added a `duration: Double?` field to `ImageMetadata` (nil for
  images; default-valued init so existing callers are unaffected).
- **`ThumbnailGenerator.makeVideoPoster(from:maxPixelSize:)`** (new, async):
  `AVAssetImageGenerator` renders a display-oriented poster (frame ~1s in to dodge
  a leading black frame), bounded to the tier size, encoded via the existing JPEG
  path.
- **`IngestPipeline`**: metadata now tries the image path first and falls back to
  the video path only when the bytes actually sniff as a movie (so a corrupt image
  still surfaces its own error). For a video the thumbnail source is the poster,
  rendered ONCE at the largest tier and reused for every tier — and only when a
  tier is actually missing (P14 short-circuit preserved). The persisted
  `AssetDraft` now carries `meta.duration`.

Storage/dedup were already medium-agnostic: the VIDEO bytes are the content-
addressed blob (`<hash>.mp4`); the poster only feeds the thumbnails.

## Known cost (deferred optimization)
The pipeline reads the source into one `Data`, and the video metadata/poster steps
each re-write it to a temp file for AVFoundation. For a large clip that's a
transient buffer + up to two temp copies. Acceptable for single-user local capture;
threading the file URL straight through (avoiding re-buffering) is a later
optimization.

## Files changed
- `Sources/.../Imaging/MediaProbe.swift` (new),
  `Imaging/ImageMetadata.swift` (+duration, +videoMetadata),
  `Imaging/ThumbnailTier.swift` (+makeVideoPoster),
  `Pipeline/IngestPipeline.swift` (image-first/video-fallback, poster tiers).
- Tests: `TestSupport/FixtureVideos.swift` (new — AVAssetWriter MP4 fixture),
  `VideoIngestTests.swift` (new, 5 tests).

## Verification
- `swift test` (AtelierIngestion) → **69/69** (5 new video tests: sniff, metadata,
  poster bounds, end-to-end .video asset + tiers + duration, dedup).

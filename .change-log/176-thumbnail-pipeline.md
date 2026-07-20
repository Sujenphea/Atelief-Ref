# 176 — Thumbnail pipeline (036 §4 C1)

Step 1 of the amended `036` sequence: the bucketed, byte-budgeted,
fully-decoded thumbnail pipeline. Infrastructure only — **no call site moves
yet** (that is C3), so `ThumbnailCache` stays in place and in use and this
commit changes no rendering behavior.

## Summary

**`AtelierIngestion` — `ImageDecoding` made public, two gaps closed.** The
`CGImageSourceCreateThumbnailAtIndex` dance (always-synthesize + EXIF
transform) already existed and is shared by `ThumbnailGenerator`,
`PerceptualHash` and `ColorExtractor`; a second decoder in `AtelierRefs` would
have been free to drift from it. Instead:

- `ImageDecoding` and `thumbnailCGImage(from:maxPixelSize:)` are now `public`.
- Added a **`URL` overload** so the grid path doesn't read whole files into
  memory to hand them straight to ImageIO — `CGImageSourceCreateWithURL` reads
  only what the thumbnail needs.
- Added **`DecodedThumbnail`** (`image` + `byteCost = bytesPerRow * height`) and
  `decodedThumbnail(from:…)` for both `Data` and `URL`, because a byte-budgeted
  cache needs the cost and shouldn't reinvent the arithmetic per call site.
- Added a defaulted `cacheImmediately:` parameter
  (`kCGImageSourceShouldCacheImmediately`).

**`AtelierRefs/ThumbnailPipeline.swift` — new.** Pure ladder
`thumbnailPixelBucket(pointLongSide:scale:)` snapping UP to
{128, 192, 256, 384, 512} (512 = on-disk tier ceiling);
`thumbnailFallbackBuckets(for:)`; `thumbnailCacheCostLimit(physicalMemory:)`.
`ThumbnailPipeline` provides a bucket-tolerant sync `cached`/`cachedEntry`,
coalesced `image(hash:url:bucket:) async` at `.userInitiated`, and
`prefetch`/`cancelPrefetch` at `.utility` behind a max-4-concurrent gate that
visible requests bypass and promote out of. `NSCache` keyed `"hash#bucket"`,
cost = decoded bytes, `totalCostLimit = clamp(physicalMemory/16, 128…512 MB)`,
**no countLimit**. The API is hash + url + bucket and nothing else — no SwiftUI
types — so the SwiftUI cells (C3) and an `NSCollectionViewPrefetching`
coordinator (Workstream A) can both drive it unchanged.

## Measurement, and what it does to the 036 §5 prediction

C1 exists to test one hypothesis, so the numbers matter more than the code.
Measured against the real public API over the **512 px on-disk tier file the
grid actually loads** (medians of 20, `MacBookPro18,3`):

| path | build | first draw |
|---|---|---|
| `NSImage(data:)` (today) | 0.11 ms | **1.07 ms**, on main |
| pipeline, bucket 256 | 0.59 ms | 0.12 ms |
| pipeline, bucket 384 | 1.91 ms | 0.20 ms |
| pipeline, bucket 512 | 0.86 ms | 0.30 ms |

**The mechanism 036 §5 named is real and is now quantified**: `NSImage` does
defer its decode to first draw, and that draw is on the main thread. C1 moves
~0.9 ms per newly visible cell off it — roughly **8–11 ms per band crossing** at
8–12 new cells.

**But that is a partial explanation, not a complete one.** The measured worst
frame at 200 items / wrappers stripped / warm was 44 ms. Removing 8–11 ms of it
is the right order of magnitude to matter and the wrong order of magnitude to
be the whole story. So §5's prediction — "if the prediction is right, step 4
cancels A1–A4" — should be read with a wider interval than it was written with:
C1 alone reaching Smooth is **plausible, not expected**. `038` §3.3 already
measured the per-cell wrappers as the largest SwiftUI-side effect, and this
result puts C1 in a comparable band rather than a dominant one, which
strengthens `038` §5's closing suggestion that the candidate cheap path is
**C1 + C4 together**. If the step-4 gate is run after C1 only and comes back
Not smooth, that is *not* yet a framework verdict — C4 has to land first.

**Correction owed to `036` §4 C1 and to the bake-off's `AppKitBakeoffGrid`
comment.** Both attribute the eager decode to
`kCGImageSourceShouldCacheImmediately`. Measured with the flag on and off across
two buckets, build and first-draw times are identical to within noise: for the
`CGImageSourceCreateThumbnailAtIndex` path **the flag is a no-op**, because
thumbnail synthesis already returns a rasterized bitmap. The win is
`CreateThumbnailAtIndex` (and bucketing) versus `NSImage`'s lazy provider. The
flag is still passed — it states the requirement and becomes load-bearing for
any future full-size `CGImageSourceCreateImageAtIndex` decode — but it is not
the mechanism, and the AppKit mode's advantage was therefore never attributable
to it either.

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Imaging/ImageDecoding.swift` — public, URL
  overload, `DecodedThumbnail`, `cacheImmediately:`.
- `AtelierRefs/AtelierRefs/ThumbnailPipeline.swift` — new.
- `AtelierRefs/AtelierRefsTests/ThumbnailPipelineTests.swift` — new; 22 tests.

## Migration notes

- **No behavior change.** Nothing calls `ThumbnailPipeline` yet; `ThumbnailCache`
  is untouched and still serves every thumbnail. C3 migrates the call sites and
  deletes it.
- The three existing `ImageDecoding` consumers are **source- and
  behavior-identical**: `cacheImmediately` defaults to `false`, which leaves the
  options dictionary byte-for-byte as it was. Full `AtelierRefsTests` suite green
  (348 tests) and the `AtelierIngestion` package suite green.
- Widening a package type to `public` is an API commitment: `ImageDecoding`,
  `DecodedThumbnail`, and the four decode entry points are now part of
  `AtelierIngestion`'s surface.
- `DecodedThumbnail` is deliberately **not** `Sendable` (`CGImage` isn't).
  Consumers decode where they use it; the pipeline never lets one cross an
  isolation boundary — decodes store into the cache on the decode thread and
  callers re-read via the synchronous `cached`.

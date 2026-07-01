# 017 — Ingestion: Imaging utilities (hash / metadata / thumbnails)

**Chunk 3** of the ingestion build: the pure, stateless image utilities —
content hashing (C5), byte-derived metadata extraction (C7), and eager
fixed-tier thumbnail generation (A4/P13) — plus synthetic test fixtures (T9) and
the extraction/thumbnail test suites (T11). No `MediaStore` writes, no pipeline,
no coordinator (chunk 4). Everything here is a stateless function over
`Data`/`URL`.

## Summary

### `ContentHasher` (C5)
SHA-256 via CryptoKit, formatted as 64-char **lowercased hex** — the `blob_hash`.
- `static func hash(_ data: Data) -> String` — one-shot in-memory.
- `static func hash(contentsOf url: URL) throws -> String` — **streamed** through
  a `FileHandle` in 1 MiB chunks fed to an incremental `SHA256`, so a large file
  is never fully resident. Produces the identical digest to `hash(_:)` over the
  same bytes.

### `ImageError`
`public enum ImageError: Error, Equatable` — `.unreadable`,
`.unsupportedType(mime: String?)`, `.decodeFailed`, `.thumbnailFailed`. Chunk 4's
`IngestError` will wrap these.

### `ImageMetadata` + `extract(from:)` (C7)
`public struct ImageMetadata: Sendable, Equatable { width; height; mimeType;
kind: AssetKind; fileExtension }`. `static func extract(from data: Data) throws
-> ImageMetadata` via ImageIO:
- dims from `kCGImagePropertyPixelWidth/Height`, then **EXIF orientation
  applied** (`kCGImagePropertyOrientation`): orientations 5–8 (90°/270°) SWAP
  width/height, so the returned dims are **display-oriented**.
- MIME / kind / extension from `CGImageSourceGetType` → `UTType`:
  `preferredMIMEType` / `preferredFilenameExtension`; conforms to `.image` →
  `.image`, `.movie`/`.audiovisualContent` → `.video`, else
  `.unsupportedType`.
- zero bytes / unrecognized container → `.unreadable`; recognized-but-no-dims
  (corrupt/truncated) → `.decodeFailed`. NEVER trusts a filename — `extract`
  takes only `Data`, so it is inherently extension-independent.

### `ThumbnailTier` + `ThumbnailGenerator` (A4/P13)
- `public enum ThumbnailTier: Int, CaseIterable, Sendable` — `small = 128`,
  `medium = 512`, `large = 1280`; `rawValue` is the max pixel size, mirroring the
  canvas LOD tiers.
- `ThumbnailGenerator.makeThumbnail(from:maxPixelSize:)` uses
  `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize`
  (decode **direct to target size** — no full-res bitmap, P13),
  `…FromImageAlways`, and `…WithTransform` (applies EXIF orientation so the
  thumbnail is display-oriented, matching `ImageMetadata`'s dims). Encodes to
  **JPEG** (`CGImageDestination`, quality 0.8). Plus a
  `makeThumbnail(from:tier:)` convenience. Failure → `.decodeFailed` /
  `.thumbnailFailed` / `.unreadable`.

## EXIF orientation — applied in BOTH paths

- **Extraction**: `displayDimensions(pixelWidth:pixelHeight:orientation:)` swaps
  W/H for orientation 5–8 so stored dims become display dims (e.g. stored
  100×60 orientation 6 → reported 60×100).
- **Thumbnailing**: `kCGImageSourceCreateThumbnailWithTransform = true` bakes the
  orientation transform into the decoded thumbnail, so its pixel dims are
  display-oriented for free — no manual swap needed on the thumbnail bytes.

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Imaging/ContentHasher.swift` *(new)*
  — `public enum ContentHasher`, `import CryptoKit`; streamed + in-memory SHA-256.
- `AtelierIngestion/Sources/AtelierIngestion/Imaging/ImageError.swift` *(new)* —
  `public enum ImageError: Error, Equatable`.
- `AtelierIngestion/Sources/AtelierIngestion/Imaging/ImageMetadata.swift` *(new)*
  — `public struct ImageMetadata` + `extract(from:)`, `classify(_:)`,
  `displayDimensions(...)`; imports `AtelierCore` for `AssetKind`.
- `AtelierIngestion/Sources/AtelierIngestion/Imaging/ThumbnailTier.swift` *(new)*
  — `public enum ThumbnailTier` + `public enum ThumbnailGenerator`.
- `AtelierIngestion/Tests/AtelierIngestionTests/TestSupport/FixtureImages.swift`
  *(new)* — synthetic `enum FixtureImages`: `solidImage(width:height:format:)`,
  `orientedImage(pixelWidth:pixelHeight:orientation:)`, `heicImage(width:height:)`,
  `corruptImage()`, `nonImageBytes()`, `zeroBytes`. Built from a `CGContext` +
  `CGImageDestination`; no committed binaries.
- `AtelierIngestion/Tests/AtelierIngestionTests/ContentHasherTests.swift` *(new)*
  — known-answer vectors (empty, `abc`), format (64/lowercased/hex), streamed ==
  in-memory over a 3 MiB+ file, streamed empty file.
- `AtelierIngestion/Tests/AtelierIngestionTests/ImageMetadataTests.swift` *(new)*
  — parameterized PNG/JPEG dims+MIME+kind+ext; HEIC (real, not skipped, in this
  env); EXIF-6 swap; pure `displayDimensions` matrix; MIME-from-bytes;
  corrupt/zero/non-image → typed errors.
- `AtelierIngestion/Tests/AtelierIngestionTests/ThumbnailGeneratorTests.swift`
  *(new)* — downscale+aspect at `.medium`; per-tier max-dim bound (all tiers);
  EXIF transform (portrait result); corrupt + zero throw.

## Verification

- `cd AtelierIngestion && swift test` — **38 tests in 5 suites passed**, ~0.6s
  (18 new imaging tests across ContentHasher/ImageMetadata/ThumbnailGenerator,
  plus the chunk-1/2 skeleton + MediaStore suites).
- Known-answer SHA-256 confirmed: empty →
  `e3b0…b855`, `abc` → `ba78…15ad`; streamed `hash(contentsOf:)` == in-memory
  `hash(_:)` for a >3 MiB file (multiple chunk cycles).
- HEIC encoding IS available in this test env — the HEIC test exercised real
  `image/heic` metadata rather than the graceful-skip guard.

## Notes

- `FixtureImages.corruptImage()` truncates the JPEG deterministically **at its
  SOF marker** (which carries the frame dimensions), not by a fixed fraction:
  macOS 26 ImageIO reads dims from a JPEG truncated to half its bytes, so a
  fractional cut is unreliable. The SOF cut guarantees a recognized-but-
  undecodable JPEG (`type == public.jpeg`, no dims, no thumbnail).
- JPEG/HEIC encodings are not byte-deterministic; all tests assert on decoded
  dims / decodability / MIME, never on exact bytes.

## Migration notes

None — additive. New public surface in `AtelierIngestion`
(`ContentHasher`, `ImageError`, `ImageMetadata`, `ThumbnailTier`,
`ThumbnailGenerator`), not yet wired into the pipeline (chunk 4) or the app.

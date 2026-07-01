# 016 — Ingestion: MediaStore (content-addressed blob + thumbnail store)

**Chunk 2** of the ingestion build: the content-addressed, sharded file store
for blobs and thumbnails, with atomic + idempotent writes and existence checks
(decisions C6 / A2, tests T10). Pure file/bytes layer — no image decoding, no
hashing, no pipeline (those land in later chunks).

## Summary

Added `MediaStore`, a `Sendable` value type over a `LibraryLayout` that turns a
caller-supplied lowercased-hex content `hash` + a file-extension string into a
deterministic, 2-level sharded path (`blobs/ab/cd/<hash>.<ext>`, thumbnails
`thumbnails/ab/cd/<hash>@<size>.<ext>`) and reads/writes `Data` there.

The store upholds the A2 invariant — **a blob file that exists is complete and
valid** — via an atomic, idempotent write:

1. If the destination already exists, return it immediately (idempotent no-op;
   content-addressing ⇒ identical bytes, so no rewrite).
2. Otherwise ensure the shard dir exists, then write the bytes to a UNIQUE
   `UUID`-named temp file inside `cache/`. `cache/` shares the Library root
   volume with the destination, so the next step is a metadata-only rename, not
   a copy.
3. Atomically move temp → destination via `FileManager.moveItem(at:to:)`. The
   rename is what makes the destination appear atomically — a reader never sees
   a half-written file.
4. Concurrent-race catch: if the move fails only because the destination now
   exists (a concurrent writer of the same bytes won), delete the temp file and
   treat it as success — return the destination, do not surface an error. Any
   other error: delete the temp file (never leak it), then rethrow.

Net guarantee: the content-addressed path only ever holds COMPLETE bytes; a
crash mid-write leaves at most a harmless stray temp file in `cache/`, never a
partial blob.

Image/mime knowledge is kept OUT: `fileExtension` is an opaque string; hashing
is a chunk-3 concern.

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Media/LibraryLayout.swift` *(new)*
  — `public struct LibraryLayout: Sendable`: wraps a `root` URL, exposes the
  `blobs` / `thumbnails` / `cache` subdirectories as computed URLs (003 storage
  layout). Pure path math; creates nothing.
- `AtelierIngestion/Sources/AtelierIngestion/Media/MediaStore.swift` *(new)* —
  `public struct MediaStore: Sendable` over a `LibraryLayout` (init from a root
  URL or a layout). Public API: `blobURL` / `hasBlob` / `storeBlob` / `readBlob`
  and the thumbnail mirror `thumbnailURL` / `hasThumbnail` / `storeThumbnail` /
  `readThumbnail`; `StoreError.invalidHash` for a hash under 4 hex chars;
  internal `shardComponents(for:)`; private `atomicWrite(_:to:shardDirectory:)`.
- `AtelierIngestion/Tests/AtelierIngestionTests/TestSupport/TempLibrary.swift`
  *(new)* — `makeTempLibrary()` builds a `MediaStore` in a unique temp dir with
  `cleanup()` (mirrors AtelierCore's `makeTempDatabase()`).
- `AtelierIngestion/Tests/AtelierIngestionTests/MediaStoreTests.swift` *(new)* —
  the T10 suite (18 tests): deterministic sharded paths (blob/thumbnail, empty
  ext, differing sizes), `shardComponents` split + short-hash guard, blob +
  thumbnail round-trips, idempotent write (single file, no-op URL, first content
  preserved), shard dirs created, no stray temp / complete destination,
  concurrent same-bytes race (32 tasks → one file, none throw), `hasBlob` /
  `hasThumbnail` transitions, missing-read throws.

## Verification

- `cd AtelierIngestion && swift test` — **20 tests in 2 suites passed** (the 18
  new `MediaStore` tests plus the 2 chunk-1 skeleton smoke tests), 0.014s.

## Migration notes

None — additive. `MediaStore` / `LibraryLayout` are new public surface in
`AtelierIngestion`, not yet wired into the pipeline (chunk 4) or the app. The
store performs no image decoding or hashing; callers supply the content hash and
file extension.

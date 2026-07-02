# 042 — Ingestion: MediaStore trash + MediaReaper

## Summary

Gives the media layer a delete path (it was append-only). `MediaStore` gains
`removeBlob` / `removeThumbnail`, which move a content-addressed file to the
user's **Trash** (`FileManager.trashItem`, so the media stays recoverable),
idempotently (an absent file → `nil`, no error) and return the new Trash URL.

`MediaReaper` composes them: given an `OrphanedBlob` (from
`AppServices.deleteAssets`) it trashes the blob — its stored extension recovered
from the mime type via `ImageMetadata.fileExtension(forMIMEType:)`, the same
round-trip readers use — plus every `ThumbnailTier` (`@<size>.jpg`). It is the
single home for the delete-side layout, symmetric to `IngestPipeline`'s write
side. Best-effort: the DB rows are already gone, so a file that can't be moved is
harmless leftover disk, not a correctness bug.

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Media/MediaStore.swift` —
  `removeBlob`, `removeThumbnail`, private `trash(_:)`.
- `AtelierIngestion/Sources/AtelierIngestion/Media/MediaReaper.swift` (new).
- `AtelierIngestion/Tests/AtelierIngestionTests/MediaReaperTests.swift` (new) —
  7 tests: blob/thumbnail trashing + idempotency, tier isolation, extension
  derivation (png/jpeg), absent-file no-op, `[OrphanedBlob]` batch. Trashed files
  are cleaned up from the returned URLs so the suite never pollutes real Trash.

## Migration notes

None — additive API. `Sendable`, so the reaper can run off the main actor.

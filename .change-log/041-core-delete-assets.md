# 041 — Core: deleteAssets (whole-library delete + dedup-safe blob GC)

## Summary

Adds `AppServices.deleteAssets(_:) -> [OrphanedBlob]` — the destructive
counterpart to the membership-only `removeAssets`. In one write transaction it
removes each existing target `asset` row (cascading its memberships and tag
links, clearing any folder cover), garbage-collects sources whose last asset is
gone, and returns the blobs that are now reclaimable so a higher layer can trash
their files. Idempotent on unknown / already-deleted ids.

Reference counting is done inside the transaction, so the result is **dedup-safe**:
a `blob_hash` is reported only when no remaining asset shares it, and a `source`
is GC'd only when its last asset is removed. Core never touches the filesystem —
it reports `OrphanedBlob { blobHash, mimeType }` and lets the caller reclaim
files (AtelierCore does not depend on AtelierIngestion's `MediaStore`).

## Files changed

- `AtelierCore/Sources/AtelierCore/Services/OrphanedBlob.swift` (new) — the
  GRDB-free reclaimable-blob DTO (`Sendable`, `Hashable`).
- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` — `deleteAssets`.
- `AtelierCore/Tests/AtelierCoreTests/ServicesDeleteTests.swift` (new) — 10 tests:
  full teardown, cross-folder cascade, shared-hash NOT orphaned (one then both),
  shared-source NOT GC'd, tag-link cascade with tag row surviving, cover SET NULL,
  unknown-id / double-delete idempotency, deduped batch.

## Migration notes

None — no schema change (the cascades already existed in the v1/v2 schema). New
public API only; existing callers are unaffected.

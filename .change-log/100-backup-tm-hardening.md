# 100 — Backup: Time Machine hardening (008 H2)

Fulfills the `LibraryLayout` doc-comment's long-standing promise that
`thumbnails/` is "excluded from backups" — nothing implemented it until now
([008-backup](../.docs/feature-todo/008-backup.md), H2).

## Summary

- **`MediaStore.excludeDerivedFromBackup()`**: creates `thumbnails/` + `cache/`
  (the flag needs an existing URL) and sets `isExcludedFromBackup` on each. They
  hold only regenerable data, so Time Machine / iCloud skip them — smaller,
  faster backups. `blobs/` (irreplaceable originals), the database, and
  `snapshots/` are deliberately NOT excluded. Per-directory failures are
  swallowed (hygiene, not correctness).
- **Bootstrap wiring**: `IngestionModel.bootstrap()` calls it after opening the
  store — idempotent and cheap, safe every launch.

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Media/MediaStore.swift` —
  `excludeDerivedFromBackup()`.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — call it in `bootstrap()`.
- `AtelierIngestion/Tests/AtelierIngestionTests/MediaStoreTests.swift` — test
  (thumbnails/cache excluded, blobs left included).

## Migration notes

None — a filesystem resource flag on derived dirs; no schema change.

## Tests

AtelierIngestion 19 green (incl. the new exclusion test); app builds clean.

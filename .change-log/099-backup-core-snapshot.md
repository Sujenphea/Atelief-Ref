# 099 — Backup: Core snapshot + integrity (008 H1)

First slice of the backup safety net ([008-backup](../.docs/feature-todo/008-backup.md),
H1). Adds the two Core primitives every snapshot/restore path builds on. Scope
for this pass is **H1–H3** (the snapshot safety net); off-device backup (H4–H5)
and portability export (H6–H7) are deferred. Confirmed policy: auto-snapshot on
launch when >1 day stale; retention 7 daily + 4 weekly + all pre-migration.

## Summary

- **`AppServices.snapshot(to:)`** — a single `VACUUM INTO` producing a
  checkpointed, self-consistent `.sqlite` copy with no `-wal` sidecar. `VACUUM`
  can't run in a transaction, so it takes the pool's `writeWithoutTransaction`
  rather than the `write {}` funnel; errors still map to `AtelierError`. SQLite
  refuses to overwrite, so the destination must be fresh.
- **`AppServices.integrityCheck()`** — `PRAGMA integrity_check` on the live DB →
  `true` only on the single `ok` row.
- **`AppServices.isHealthy(databaseFileAt:)`** (static) — integrity-checks a
  snapshot/backup FILE read-only, off the live pool, so restore can refuse an
  unhealthy snapshot before installing it. Keeps GRDB confined to Core (A2).

## Package note (deviation from the doc)

The 008 doc proposes an `AtelierBackup` package for the GRDB-free orchestration.
For H1–H3 the primitive lives in Core (above) and the manager will live in the
app target — the package's value is confining the larger blob-copy / manifest /
importer surface that only arrives in H4–H7, and hand-editing the stable-hex
`project.pbxproj` for a package this small is unwarranted risk. Revisit when
off-device/export land.

## Files changed

- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` — `snapshot(to:)`,
  `integrityCheck()`, `isHealthy(databaseFileAt:)`.
- `AtelierCore/Tests/AtelierCoreTests/ServicesSnapshotTests.swift` — new (4 tests).

## Migration notes

None — snapshots are file artifacts; no schema change.

## Tests

Core **230** green (226 + 4 new): snapshot round-trip (reopened copy's
collection/asset/tag rows equal the source), live integrity pass, snapshot-file
health check off the pool, and overwrite-refused.

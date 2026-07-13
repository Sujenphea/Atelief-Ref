# 101 — Backup: pre-migration snapshot hook + naming (008 H3a)

The automatic safety net for migrations ([008-backup](../.docs/feature-todo/008-backup.md),
H3): opening a library whose on-disk schema is behind copies it aside as a
`pre-migration-…` snapshot before migrating — a recovery point in case a schema
migration corrupts data. This is the protection the risky 003 rebuild (and every
future migration) leans on.

## Summary

- **`SnapshotFile` / `SnapshotReason`** (Core value types): snapshots are named
  `<reason>-<yyyyMMdd-HHmmss>-<id>.sqlite` (UTC, lexically sortable). The reason
  prefix (`daily` / `manual` / `pre-migration` / `pre-destructive`) lets the app's
  retention treat pre-migration snapshots as sacrosanct. `makeURL` builds names;
  `init?(url:)` parses them (longest prefix wins). Pure naming — no orchestration.
- **`LibraryDatabase.init` pre-migration hook**: stages a copy of the existing DB
  (+ `-wal`/`-shm`) *before the pool opens* (safe — no writer yet), opens the
  pool, and keeps the copy as a `pre-migration-…` snapshot **only if a migration
  is actually pending** (checked via a read-write pool read, sidestepping the
  readonly-WAL open hazard); otherwise discards it. A fresh library snapshots
  nothing. All backup failures are swallowed — a hiccup never blocks opening.

## Files changed

- `AtelierCore/Sources/AtelierCore/Services/SnapshotFile.swift` — new.
- `AtelierCore/Sources/AtelierCore/Persistence/LibraryDatabase.swift` — the
  pre-migration stage/finalize hook in `init`.
- `AtelierCore/Tests/AtelierCoreTests/PreMigrationSnapshotTests.swift`,
  `SnapshotFileTests.swift` — new.

## Migration notes

None — snapshots are file artifacts; no schema change. The hook runs on every
open but only writes when migrations are pending.

## Tests

Core **235** green (+5): behind-schema open snapshots once (and the snapshot is a
healthy openable DB), up-to-date/re-open adds none, fresh library takes none;
name make→parse round-trips reason + second-precision timestamp; parsing rejects
non-snapshots; longest reason prefix wins.

# 290 — Backup hardening: normalized snapshots, atomic restore, surfaced nets

Implements every decision from the 2026-07-31 review of 008's as-built H1–H3
(all 16 issues user-confirmed; see 008's settled-decisions log). The 008 doc is
re-baselined to as-built reality in the same change.

## Summary

- **Snapshots are now one self-contained file** (6A): pre-migration file copies
  are normalized at promotion (checkpoint + `journal_mode=DELETE`). Root cause,
  verified on macOS 26: macOS SQLite is persistent-WAL, and a read-only open of
  a WAL-mode file *requires* its sidecars (`SQLITE_CANTOPEN` without them) —
  the review's original "sidecars break the health check" hypothesis was
  inverted; it's their *absence* on a WAL-mode file that breaks it.
  Normalization runs at promotion, never staging, so the every-launch staging
  path stays an APFS clone + delete (15A).
- **Atomic restore install** (5A): `applyPendingRestore` copies the snapshot to
  a staging name first, moves the live set aside, then renames into place;
  the failure path clears staging litter *before* the rollback check. A partial
  copy can no longer masquerade as the live DB. `stageRestore` folds
  open-failures into the typed `.unhealthySnapshot`.
- **`SQLiteFileSet`** (7A, new in Core): the `{db, -wal, -shm}` trio as one
  unit (strict copy/move, best-effort remove, summed size); replaces seven
  hand-rolled sidecar loops across `LibraryDatabase` and `SnapshotManager`.
- **Safety nets surface failures, never block** (8A): a failed pre-migration
  snapshot drops `.pre-migration-snapshot-failed`, consumed + toasted once at
  bootstrap; a failed pre-destructive snapshot logs + toasts and the delete
  proceeds (in-DB recoverable backup still covers it). Retention exempts
  pre-destructive snapshots younger than 30 days.
- **Post-restore blob reconcile** (3A): a successful restore drops
  `.just-restored`; the next bootstrap *reports* referenced-but-missing blobs
  ("may still be in the Trash") and skips that launch's orphan GC, reporting
  unreferenced-but-kept blobs (captured after the snapshot) instead of silently
  trashing them.
- **Performance** (13A/14A): the daily-on-launch snapshot moved off the
  bootstrap critical path into a background task after content loads;
  `snapshotBeforeDestruction` skips the per-delete `VACUUM INTO` when any
  snapshot is <10 minutes old.
- **Testability** (11A): `SnapshotManager` takes an injected `now` clock.
- **Tests** (9A/10A/12A): unclean-WAL repro (red-first against the old
  behavior); restore failure-path suite (empty/dangling/unhealthy marker,
  install-failure rollback via an unwritable dir, crash resume, restore over a
  corrupt live DB); aside-content verification ("set aside, not deleted" is now
  asserted); manager-level prune-over-real-files; byteSize sidecar pin;
  staleness boundary, freshness gate, floor, and marker-consumption tests;
  `SQLiteFileSetTests`. Full runs green: AtelierCore 559 tests, AtelierRefs
  app suite.

## Files changed

- `AtelierCore/Sources/AtelierCore/Persistence/LibraryDatabase.swift` —
  normalization at promotion, APFS-clone invariant comment, strict staging via
  `SQLiteFileSet`, failure-marker recording, `finalize…` returns success.
- `AtelierCore/Sources/AtelierCore/Services/SQLiteFileSet.swift` — new.
- `AtelierRefs/AtelierRefs/SnapshotManager.swift` — atomic staged install,
  injected clock, freshness gate, retention floor, `.just-restored` +
  `.pre-migration-snapshot-failed` consumption, `PostRestoreBlobReport`,
  file-set adoption in byteSize/delete/prune.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — bootstrap surfacing of the
  pre-migration failure, post-restore reconcile branch replacing that launch's
  orphan GC, daily snapshot into a background task, gated + surfaced
  pre-destructive snapshot at the delete site.
- Tests: `AtelierCore/Tests/AtelierCoreTests/PreMigrationSnapshotTests.swift`,
  `…/SQLiteFileSetTests.swift` (new),
  `AtelierRefs/AtelierRefsTests/SnapshotManagerTests.swift`.
- Docs: `.docs/feature-todo/008-backup.md` re-baselined (status, as-built
  deviations, H4–H7 respec, review decision log).

## Migration notes

None — zero schema changes. On-disk behavior changes are additive: new marker
files under `snapshots/` (`.pre-migration-snapshot-failed`, `.just-restored`),
and newly-promoted pre-migration snapshots are sidecar-free (older
sidecar-carrying snapshots remain restorable via the compatibility net).

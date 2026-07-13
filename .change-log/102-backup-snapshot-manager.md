# 102 — Backup: snapshot manager + auto-triggers (008 H3b)

The app-side snapshot orchestration ([008-backup](../.docs/feature-todo/008-backup.md),
H3): snapshots now get taken automatically and pruned on a retention policy.
Restore + the manual UI land next (H3c).

## Summary

- **`LibraryLayout.snapshots`**: the `snapshots/` dir accessor (a recovery
  artifact — and, unlike thumbnails/cache, NOT excluded from backups).
- **`SnapshotRetention`** (pure): the subset to delete — keep the 7 newest rolling
  snapshots, then the newest in each of up to 4 further ISO weeks; **pre-migration
  snapshots are never pruned**. Unit-tested directly.
- **`SnapshotManager`** (app, GRDB-free): `list()`, `snapshot(reason:)` (takes via
  Core's `AppServices.snapshot(to:)` then prunes), `snapshotIfStale(maxAge:)`
  (daily-on-launch), `prune()`.
- **Wiring** (`IngestionModel.bootstrap`): construct the manager; run
  `snapshotIfStale()` on launch (confirmed on-by-default, >1 day). And in
  `confirmPendingDeletion` a **pre-destructive** snapshot precedes
  `deleteAssets` — both best-effort so a backup hiccup never blocks the user.

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Media/LibraryLayout.swift` —
  `snapshots` accessor.
- `AtelierRefs/AtelierRefs/SnapshotManager.swift` — new (retention + manager).
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — construct + daily-on-launch +
  pre-destructive hook.
- `AtelierRefs/AtelierRefsTests/SnapshotManagerTests.swift` — new (4 tests).

## Migration notes

None — snapshots are file artifacts.

## Tests

App `SnapshotManagerTests` green (4): retention keeps 7+4 & exempts pre-migration
(and exempts them even when they're the oldest many); manager snapshot writes a
healthy openable file that `list()` reports; the stale check takes one daily then
no-ops while it's fresh. Core 235 + Ingestion 19 unaffected.

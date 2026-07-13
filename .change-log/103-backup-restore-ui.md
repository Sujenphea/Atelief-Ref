# 103 — Backup: restore + manual snapshot UI (008 H3c)

Completes the snapshot safety net ([008-backup](../.docs/feature-todo/008-backup.md),
H1–H3): restore, plus a manual surface. "An unrestorable backup is theater" — so
restore is a real, tested round trip.

## Summary

- **Restore (staged, applied at next launch)** — the live DB can only be swapped
  safely *before the pool opens*, so restore is deferred to relaunch rather than
  torn down live:
  - `SnapshotManager.stageRestore(_:)` integrity-checks the snapshot and writes a
    `.pending-restore` marker naming it.
  - `SnapshotManager.applyPendingRestore(snapshotsDir:livePath:)` runs at
    bootstrap **before** `AppServices` opens: moves the live DB (+ sidecars) aside
    as `library.corrupt-<epoch>.sqlite` (**never destroyed**), copies the snapshot
    into place, clears the marker. A failure mid-swap rolls the live DB back; a
    bad marker is cleared. (A restored older snapshot then re-migrates forward via
    the H3a pre-migration hook.)
  - `SnapshotError.unhealthySnapshot` when a chosen snapshot fails integrity.
- **Manual surface**: `SnapshotsSheet` lists snapshots (time + reason) with a
  per-row Restore (confirmation dialog) and a "Snapshot Now" button;
  `IngestionModel` gains `snapshotNow()`, `availableSnapshots()`,
  `stageRestore(_:)`, and the relaunch-prompt alert. File-menu commands
  ("Snapshot Now", "Restore from Snapshot…") reach the model via a new
  `ingestionModel` focused-scene value.

## Files changed

- `AtelierRefs/AtelierRefs/SnapshotManager.swift` — restore stage/apply + error.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — restore-apply in bootstrap;
  snapshot/restore actions + sheet state.
- `AtelierRefs/AtelierRefs/SnapshotsSheet.swift` — new.
- `AtelierRefs/AtelierRefs/AppShellView.swift` — sheet + alert + focused value.
- `AtelierRefs/AtelierRefs/AtelierRefsApp.swift` — File-menu backup commands.
- `AtelierRefs/AtelierRefsTests/SnapshotManagerTests.swift` — restore round-trip.

## Migration notes

None. Restore sets the current library aside (`library.corrupt-<epoch>.sqlite`)
rather than deleting it — recoverable if a restore was a mistake.

## Tests

App **55** green (+5 snapshot suite incl. the restore round trip: snapshot →
mutate → stage → apply → the reopened library is reverted, the marker is
consumed, and the displaced live DB is preserved aside).

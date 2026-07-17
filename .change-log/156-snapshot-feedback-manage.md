# 156 — Snapshots: in-progress feedback + manageable list (034 P2)

## Summary

The snapshots sheet gave no sign a manual "Snapshot Now" was running, and the list
was read-only — no size, no way to prune a specific backup. Both addressed:

1. **In-progress feedback.** `snapshotNow()` now sets a published `isSnapshotting`
   flag; the button shows a spinner + "Saving…" and disables (also guarding against
   a double-tap) until the write completes.
2. **Sizes.** Each row shows its on-disk size (incl. `-wal`/`-shm` sidecars), and a
   footer shows the count + total footprint.
3. **Manual prune.** A trash button per row deletes that snapshot (with a
   confirmation) — honouring a manual delete of ANY snapshot, including
   pre-migration ones that auto-retention keeps forever. The live library is never
   touched.

A `snapshotsVersion` signal re-reads the list when a snapshot lands or is deleted.

## Files changed

### AtelierRefs
- `SnapshotManager.swift` — `byteSize(of:)` (with sidecars) and `delete(_:)`.
- `IngestionModel.swift` — `isSnapshotting` + `snapshotsVersion` published;
  `snapshotNow` sets/clears the flag and guards re-entrancy; `snapshotByteSize`,
  `deleteSnapshot`.
- `SnapshotsSheet.swift` — spinner button, per-row size + trash (delete confirm),
  count/total footer.

### AtelierRefsTests
- `SnapshotManagerTests.swift` — `byteSizeAndDelete`.

## Migration notes

None. Retention/auto-prune behaviour is unchanged; manual delete is additive.

## Verify

- Open Snapshots (File ▸ or Settings) → **Snapshot Now** → the button shows
  "Saving…" with a spinner, then a new row appears with its size.
- Each row shows size; the footer shows "N snapshots · X total".
- Click a row's trash → confirm → it leaves the list; the live library is intact.

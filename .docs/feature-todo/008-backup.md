# 008 — Backup: Snapshots, Off-Device Backup, Portability Export

> Covers the "Backup" group: **snapshot** + **export**. Settled scope (user): all three
> goals — (a) corruption/mistake recovery, (b) machine-loss/off-device, (c)
> portability/data-freedom. Entitlement additions for (b) are **approved**. Nothing
> exists today; the README's manual `rm` is the only library lifecycle tooling.

## Current state (verified)

- Library: `<container>/Application Support/ref-atelier/` → `library.sqlite` (+WAL,
  GRDB 7.11.1 `DatabasePool`), `blobs/` (content-addressed, immutable-while-referenced),
  `thumbnails/` (regenerable tiers).
- `LibraryLayout.swift:35` **claims** thumbnails are "excluded from backups" — nothing
  implements it; `isExcludedFromBackup` appears nowhere. Time Machine currently copies
  live WAL sqlite + regenerable thumbnails.
- Entitlements: sandbox, `files.user-selected.read-only`, network client/server —
  **no read-write, no security-scoped bookmarks** → writing to a user-chosen folder is
  currently impossible.
- `MediaReaper` (`MediaReaper.swift:41`) moves orphaned blobs + thumbnails to **Trash**
  (not `rm`) after `deleteAssets` reference-counting — the immutability caveat every
  snapshot design must reconcile.
- GRDB 7 exposes `backup(to:)`; SQLite on macOS 26 supports `VACUUM INTO`.

## Architecture (cross-cutting)

New **`AtelierBackup` package** (depends on AtelierCore + AtelierIngestion). GRDB stays
confined to Core: Core gains only `snapshot(to:)` (`VACUUM INTO`) and `integrityCheck()`
(`PRAGMA integrity_check`); orchestration (retention, blob copy, manifest, restore,
progress) is GRDB-free in AtelierBackup — the same seam discipline as
MediaReaper-consumes-`OrphanedBlob`.

## (a) Snapshots — corruption/mistake recovery

### Mechanism
- **M1 — `VACUUM INTO` (recommended):** one statement through the funnel produces a
  single, checkpointed, self-consistent `.sqlite` file (no `-wal` sidecar hazard).
- M2 — GRDB `makeSnapshot()` + `backup(to:)`: works, more moving parts. Fallback only.
- M3 — file copy after `wal_checkpoint(TRUNCATE)`: fragile, mutates the live DB.
  **Rejected.**

### Blob consistency (the MediaReaper hazard, reconciled)
Snapshots are **DB-only** — blobs are immutable while referenced, so the DB file is the
state. The one hole: a snapshot's DB may reference a blob orphaned+trashed *after* the
snapshot. Mitigations: (1) snapshot **always before destructive multi-delete and before
every migration**; (2) orphans go to **Trash**, so restore can recover referenced-but-
trashed blobs best-effort. Rejected: pinning snapshot-referenced hashes in MediaReaper
(reference-counting coupling — over-engineered for goal (a)); per-snapshot blob
hardlinks (the off-device path covers full copies).

### Policy
Triggers: pre-migration (always), pre-destructive-delete, manual "Snapshot now",
optional daily-on-launch (bootstrap checks age). Retention: 7 daily + 4 weekly +
**all pre-migration snapshots** (never auto-pruned). Location: `<root>/snapshots/`
(recovery artifact, not user-facing). Size: DB-only → KB–MB each, trivial.

### Restore (an unrestorable backup is theater)
`restore(snapshot:)`: `integrityCheck` the snapshot → close the pool → move live
`library.sqlite`(+wal/shm) aside as `library.corrupt-<ts>.sqlite` → install → reopen
(migrations re-run idempotently) → `reconcileOrphanedKnownItems()`
(`AppServices.swift:797`) → best-effort Trash recovery for missing referenced blobs.
Round-trip tested.

**Effort: M.** Pre-migration hook note: before the pool first opens, a plain file copy
is safe (no writer yet) — the hook can live in `LibraryDatabase.init` ahead of
`migrate()`.

## (b) Off-device — machine loss

### Phase 1 (S) — Time Machine hardening, ship immediately
Set `isExcludedFromBackup` on `thumbnails/` (+ future `cache/`) at bootstrap — fulfills
the existing doc-comment promise, shrinks TM/iCloud footprint, derived data regenerates.

### Phase 2 (L) — user-chosen-folder incremental backup (entitlements approved)
Add `files.user-selected.read-write` + `files.bookmarks.app-scope`; folder picker →
persist a security-scoped bookmark; each run wraps
`startAccessingSecurityScopedResource()`.

Content-addressing makes incremental trivial and **idempotent/resumable**: diff live
`blob_hash` set against destination `blobs/` (same shard layout) → copy missing; write a
fresh `VACUUM INTO` DB snapshot + a small manifest. Verification: filename-is-hash means
a spot-check re-hash of sampled copied blobs is cheap; `integrityCheck` the snapshot;
optional full-verify command.

**Restore**: verify snapshot → copy blobs back (skip present) → install DB (same
swap-aside flow as (a)) → reconcile.

**iCloud Drive**: it's just a folder target for Phase 2. **Never place the live
`library.sqlite` in iCloud** (partial sync + WAL = corruption); self-contained snapshot
copies are fine. Document this sharp edge in-app (target picker help text).

Rejected: a background sync engine/daemon — the app isn't always running; manual +
on-launch-if-stale covers the need ("engineered enough").

## (c) Export — portability / data freedom

### Layout
- **X1 (recommended):** folder tree mirroring the collection hierarchy; each asset's
  original written into its collection folder(s) as `<title-or-source>-<shorthash>.<ext>`
  (sanitized); **one versioned `manifest.json`** at the root capturing the full graph —
  sources/provenance, assets, tags, collections + nesting, memberships + manual order,
  timestamps. Multi-collection assets are **copied into each folder** for human
  browsability; the manifest records the single canonical asset (no duplication in the
  contract). Optional zip wrapper.
- X2 — per-item sidecar JSONs: N files, per-membership duplication, harder atomic
  re-import. **Rejected as default.**

### Re-import is a first-class round trip
`manifest_version` is a **contract** (also records the DB `schema_version`). Import
replays through existing AppServices writers (`createCollection`, `ingest`, `applyTag`,
`addAssets`, `setGridOrder`) — validation + dedup (18A) for free; blob re-import is
idempotent by content-addressing. A newer-version manifest → refuse with a clear
message. Import targets a fresh/merge library by explicit choice — never silently
clobbers.

**Effort: L** (the importer is where the cost is).

## Schema / migration impact

**None across all three.** Snapshots/exports are file artifacts; the backup bookmark
lives in app storage, not the library.

## Phased implementation (whole feature)

1. **H1 (S):** `snapshot(to:)` + `integrityCheck()` in Core; manual snapshot action.
2. **H2 (S):** TM hardening (`isExcludedFromBackup`).
3. **H3 (M):** AtelierBackup snapshot manager — retention, pre-migration +
   pre-destructive hooks, daily-on-launch; **restore flow**.
4. **H4 (S):** entitlements + bookmark plumbing + folder picker.
5. **H5 (M):** incremental blob backup + verify + progress/cancel; backup restore.
6. **H6 (M):** manifest model + exporter.
7. **H7 (M):** importer + round-trip harness.

Do H1–H3 **early in the roadmap** — pre-migration snapshots protect the risky
[003](../030-multi-kind-items-overview.md) rebuild and every other migration.

## Test strategy

- Snapshot: produces an openable DB equal to source rows (TempLibrary); integrity pass;
  retention pruning over a fake clock/fs (pure); restore round-trip (snapshot → mutate →
  restore → rows match); pre-migration snapshot exists after a version bump.
- Backup: missing-hash diff is a pure function — empty/partial/identical/extra-at-dest;
  A→folder→B round-trip (rows + blob bytes equal); corrupted-dest-blob → verify fails;
  interrupted-run resume (idempotency). Bookmark/sandbox glue behind an injectable
  `FolderAccess` protocol.
- Export/import: manifest golden-file (de)serialization + version refusal; full
  round-trip over TempLibraries (collections/nesting/memberships/order/tags/provenance/
  blobs equal); filename sanitization matrix (illegal chars, collisions → shorthash,
  overlong); multi-collection asset → N files, 1 asset on import.

## Effort: snapshot **M** · off-device **S + L** · export **L**

## Risks & edge cases

- Restore must handle `-wal`/`-shm` sidecars and a mid-restore crash (swap-aside means
  the old DB is never destroyed).
- Disk-full during snapshot/backup → fail loudly, never prune existing artifacts on a
  failed run.
- Stale bookmark (folder moved/unplugged) → clear re-pick prompt.
- Trash recovery is best-effort (user may empty Trash) — document the window honestly.
- Huge libraries: stream export, progress + cancel; never hold all bytes in memory.
- Two libraries → one backup folder: namespace by library id.

## Settled decisions

- All three goals in scope; entitlements approved (user, 2026-07-13). AtelierBackup
  package; VACUUM INTO; DB-only local snapshots; TM hardening ships first; export→import
  is a supported round trip.
- **Multi-Mac sync is an explicit NON-GOAL** (user, 2026-07-13) — backup moves data
  off-device; nothing here attempts live reconciliation between machines, and the
  "never live sqlite on iCloud" rule stands. Revisit only as its own future epic.

## Open questions

1. Retention defaults 7 daily / 4 weekly OK?
2. Daily-on-launch auto-snapshot on, or manual + pre-migration/pre-destructive only?
3. Export duplicates multi-collection files per folder (recommended) — or a single
   `_assets/` pool + links (compact, less browsable)?
4. Zip wrapper in v1 or folder-tree only?

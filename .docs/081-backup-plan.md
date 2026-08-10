# 081 — Backup: Snapshots, Off-Device Backup, Portability Export

**Status: shipped** — all seven phases. H1–H3 in `.change-log/099`–`103`,
hardened in `290`; H4/H5 in `cfd94eb` (back up now, progress, last-run status)
and `5ff8d24` (launch cadence + sampled re-hash verification); H6 in `e37282c`
(a portable library folder plus its manifest); H7 in `00500b2` (an importer that
replays through the public writers); omissions + restore-window hardening in
`962aca5`.

All three open questions are answered by what shipped:

1. **Multi-collection assets duplicate per folder.** `LibraryArchiveWriter.swift:101`
   — "an asset in five collections is copied five [times]" — with the manifest
   recording the single canonical asset, so re-import yields N memberships and
   exactly 1 asset (`LibraryArchiveRoundTripTests:325`). No `_assets/` pool.
2. **No zip wrapper.** Folder tree only; the archive is a directory the user can
   open in Finder.
3. **Cadence is manual + on-launch-if-stale**, as a visible user preference
   rather than a hidden behaviour — `BackupCadence.swift` (H5d), three options
   deliberately far apart.

Promoted out of `feature-todo/008-backup.md`. Previously re-baselined 2026-07-31
after the plan review, when H1–H3 had shipped and H4–H7 had not; the sections
below are that respec, now describing built code.

> Covers the "Backup" group: **snapshot** + **export**. Settled scope (user): all three
> goals — (a) corruption/mistake recovery, (b) machine-loss/off-device, (c)
> portability/data-freedom. Entitlement additions for (b) were **approved**.

## Phase status

- **H1 (done)** — `AppServices.snapshot(to:)` via `VACUUM INTO`;
  `integrityCheck()`; static `isHealthy(databaseFileAt:)` (read-only file check).
- **H2 (done)** — `MediaStore.excludeDerivedFromBackup()` sets
  `isExcludedFromBackup` on `thumbnails/` + `cache/` at every bootstrap.
- **H3 (done, hardened 2026-07-31)** — `SnapshotFile` naming (Core),
  pre-migration snapshot in `LibraryDatabase.init` (Core), app-side
  `SnapshotManager` (retention, daily-on-launch, pre-destructive gate, staged
  restore), `SnapshotsSheet` UI, `SQLiteFileSet` file-set helper (Core).
- **H4–H7 (done)** — `FolderAccess` + `BackupTarget` + `BackupFolderPanel`
  (bookmarks), `BackupController` + `BackupCadence` + `BackupVerifyController`
  (incremental blob backup, verify, progress/cancel), `LibraryArchive` +
  `LibraryArchiveWriter` + `ArchiveExportController` (export), and
  `LibraryArchiveReader` + `ImportPlan` + `ImportReplay` +
  `ArchiveImportController` (import). The replay layer is the one
  [016](feature-todo/016-library-management.md) L3's competitor importers consume.

## As-built architecture (deviations from the original plan, all settled)

1. **No `AtelierBackup` package.** Primitives live in Core (`snapshot(to:)`,
   `isHealthy`, `SnapshotFile`, `SQLiteFileSet`); orchestration lives in the app
   target beside its tests (`SnapshotManager`, `SnapshotManagerTests`). The
   package's stated purpose (GRDB-free orchestration seam) is achieved by
   discipline instead of a package boundary. H4–H7 follow the same split —
   revisit only if importers ever ship outside the app.
2. **Restore is staged, not live.** `stageRestore` validates + writes a
   `.pending-restore` marker; the swap happens at next bootstrap in
   `applyPendingRestore`, before the pool opens (the only safe time to move the
   live DB). The original "close the pool → swap → reopen" design is dead.
   Install is anti-truncation by construction: snapshot **copies to a staging
   name first**, live set moves aside (`library.corrupt-<epoch>`, never
   destroyed), staging **renames** into place (same-volume, atomic per file);
   the failure path removes staging litter *before* the rollback check.
3. **Every snapshot is one self-contained `.sqlite` file.** `VACUUM INTO`
   produces that shape natively; pre-migration file copies are **normalized at
   promotion** (checkpoint + `journal_mode=DELETE`). Platform fact that forced
   this (verified on macOS 26): macOS SQLite runs persistent-WAL, and a
   **read-only open of a WAL-mode file requires its sidecars** — a bare WAL main
   file fails `SQLITE_CANTOPEN`. Normalization is deliberately at *promotion*,
   not staging: the every-launch staging copy is an APFS COW clone
   (metadata-cheap), and must stay clone + delete.
4. **The `{db, -wal, -shm}` trio moves as a unit** via `SQLiteFileSet`
   (copy/move strict, remove best-effort, summed sizes) — the one home for
   sidecar handling; sidecar paths survive only as the compatibility net for
   pre-normalization snapshots.
5. **Safety nets never fail silently** (and never block): a failed
   pre-migration snapshot drops a `.pre-migration-snapshot-failed` marker that
   bootstrap surfaces once; a failed pre-destructive snapshot logs + toasts and
   the delete proceeds (the in-DB recoverable-delete backup still protects it).
6. **Pre-destructive snapshots are freshness-gated and floor-protected**:
   `snapshotBeforeDestruction` skips when any snapshot is <10 min old (a
   pre-existing snapshot predates the destruction by definition); retention
   exempts pre-destructive snapshots younger than 30 days from pruning.
7. **Post-restore blob reconcile** (`.just-restored` marker): the first launch
   after a restore *reports* both divergence directions instead of reaping —
   referenced-but-missing blobs ("may still be in the Trash") and
   unreferenced-but-kept blobs captured after the snapshot (reclaimed by the
   *next* launch's orphan GC). The original "best-effort Trash recovery" idea is
   dead: a sandboxed app cannot enumerate `~/.Trash`.
8. **Daily-on-launch snapshot runs post-load** in a background task — the
   `VACUUM INTO` cost grows with the analysis tables and must not hold up an
   empty shell at launch.
9. **Clock is injected** into `SnapshotManager` (`now:`) so staleness
   boundaries, the freshness gate, and the retention floor are unit-tested.

### Retention (as built)

7 newest rolling + newest-per-week for 4 further ISO weeks; **pre-migration
never auto-pruned**; **pre-destructive exempt for 30 days**, then rolling.
Manual delete of ANY snapshot (including pre-migration) is honoured in the
sheet. Location: `<root>/snapshots/` — deliberately NOT excluded from backups.

## (b) Off-device — machine loss (H4–H5, not started)

- **Entitlements**: `files.user-selected.read-write` **already present**
  (shipped for other features); the only addition needed is
  `files.bookmarks.app-scope`. Folder picker → persist a security-scoped
  bookmark; each run wraps `startAccessingSecurityScopedResource()`.
- **Incremental backup**: diff live `blob_hash` set against destination
  `blobs/` (same shard layout) → copy missing; write a fresh `VACUUM INTO` DB
  snapshot + a small manifest. Content-addressing makes runs idempotent and
  resumable. Verification: spot-check re-hash of sampled copied blobs;
  `isHealthy` on the snapshot.
- **Restore reuses the ONE restore seam** (review 4A): copy missing blobs back
  into `blobs/` (content-addressed, idempotent, safe while the app runs), then
  stage the backup's DB through the existing `.pending-restore` marker — the
  relaunch applies it via the same tested `applyPendingRestore`. **No second
  swap path.**
- **iCloud Drive**: just a folder target. **Never place the live
  `library.sqlite` in iCloud** (partial sync + WAL = corruption); self-contained
  snapshot copies are fine — document in the target picker. An iCloud
  destination can hold **dataless files**: enumeration stays metadata-cheap, but
  the verify spot-check *downloads* each sampled blob — cap the sample and show
  it in progress UI.
- Rejected: background sync engine/daemon (app isn't always running); multi-Mac
  sync (explicit NON-GOAL, user 2026-07-13).

## (c) Export — portability / data freedom (H6–H7, not started)

- **X1 layout (settled)**: folder tree mirroring the collection hierarchy;
  originals named `<title-or-source>-<shorthash>.<ext>` — **reuse the shipped
  `AssetExport` base-name/sanitizer helpers and their test suite** (011 U1
  landed first; do not grow a second sanitizer). One versioned `manifest.json`
  at the root (sources/provenance, assets, tags, collections + nesting,
  memberships + manual order, timestamps). Multi-collection assets are copied
  into each folder; the manifest records the single canonical asset. Optional
  zip wrapper (open question).
- **Re-import is a first-class round trip**: `manifest_version` is a contract
  (also records `schema_version`). Import replays through existing AppServices
  writers (`createCollection`, `ingest`, `applyTag`, `addAssets`,
  `setGridOrder`) — validation + 18A dedup for free; blob re-import idempotent
  by content hash. Newer-version manifest → refuse clearly. Import targets a
  fresh/merge library by explicit choice. The replay layer is **shared with
  016's competitor importers** — build it here.
- `asset_analysis` is derived data — excluded from export (recomputable),
  included in snapshots (it's in the DB anyway).

## Phases as built

1. **H4** — `files.bookmarks.app-scope` + bookmark plumbing + folder picker:
   `FolderAccess.swift` (injectable protocol, `FolderAccessTests`),
   `BackupTarget.swift`, `BackupFolderPanel.swift`.
2. **H5** — incremental blob backup + verify + progress/cancel:
   `BackupController.swift` (`cfd94eb`), `BackupVerifyController.swift` +
   `BackupCadence.swift` (`5ff8d24`), `BackupRunSummary.swift`. Restore goes
   through the staged-restore seam — no second swap path, as specced.
3. **H6** — manifest model + exporter: `LibraryArchive.swift` (the versioned
   manifest contract), `LibraryArchiveWriter.swift`,
   `ArchiveExportController.swift` (`e37282c`).
4. **H7** — importer + round-trip harness: `LibraryArchiveReader.swift`,
   `ImportPlan.swift` (the parse↔replay vocabulary), `ImportReplay.swift`
   (`LibraryImporter`), `ArchiveImportController.swift` (`00500b2`), covered by
   `LibraryArchiveRoundTripTests`.

**The replay layer stays in the app target**, as this doc's as-built §1 decided.
[016](feature-todo/016-library-management.md) L3's competitor parsers are its
second consumer; the agreed trigger for extracting `ImportPlan` + parsers into a
package is **parser #2**, not parser #1 (settled 2026-08-10).

## Test strategy

- **Shipped** (Core: `PreMigrationSnapshotTests`, `ServicesSnapshotTests`,
  `SnapshotFileTests`, `SQLiteFileSetTests`; app: `SnapshotManagerTests`):
  snapshot round-trip + integrity + no-overwrite; behind-schema/fresh/current
  opens; **unclean-WAL repro** (live `-wal` → self-contained healthy snapshot —
  the normalization regression test); file-set copy/move/remove/size; retention
  incl. the pre-destructive floor; staleness boundary + freshness gate over the
  injected clock; restore round-trip incl. **aside-content verification**
  ("set aside, not deleted" is asserted, not assumed); restore failure paths
  (empty/dangling/unhealthy marker, install failure with rollback, crash
  resume, restore over a corrupt live DB); marker consumption (pre-migration
  failure, just-restored); post-restore report set-math; manager-level prune
  over real files; byteSize sidecar sum.
- **H4–H7 (planned)**: missing-hash diff as a pure function
  (empty/partial/identical/extra-at-dest); A→folder→B round-trip (rows + blob
  bytes equal); corrupted-dest-blob → verify fails; interrupted-run resume
  (idempotency); bookmark/sandbox glue behind an injectable `FolderAccess`
  protocol; manifest golden-file (de)serialization + version refusal; full
  export/import round-trip over TempLibraries; filename matrix stays in
  `AssetExportTests`; multi-collection asset → N files, 1 asset on import.

## Risks & edge cases (live ones)

- Restore hazards are now *reported*, not silent — but recovery from the
  backward hole is still the user's Trash; the honest window is documented in
  the post-restore toasts.
- Disk-full during snapshot/backup → fail loudly (surfaced per above), never
  prune existing artifacts on a failed run.
- Stale bookmark (folder moved/unplugged) → clear re-pick prompt (H4).
- Huge libraries: stream export, progress + cancel; never hold all bytes in
  memory (H6).
- Two libraries → one backup folder: namespace by library id (H5).

## Settled decisions

- All three goals in scope; entitlements approved (user, 2026-07-13).
- Multi-Mac sync is an explicit NON-GOAL (user, 2026-07-13).
- Export→import is a supported round trip; replay layer shared with 016.
- 2026-07-13: retention 7 daily + 4 weekly; daily-on-launch ON.
- **2026-07-31 (008 plan review, all user-confirmed)**: re-baseline this doc
  (1A); app-target home for H4–H7, no `AtelierBackup` package (2A);
  post-restore detect/report + deferred first-launch GC (3A); single restore
  seam for H5 + only the bookmarks entitlement (4A); atomic staged install
  (5A); snapshot normalization at promotion (6A/15A); `SQLiteFileSet`
  consolidation (7A); surfaced-never-blocking net failures + 30-day
  pre-destructive floor (8A); failure-path/WAL-repro/clock/assertion test
  hardening (9A/10A/11A/12A); daily snapshot off the bootstrap critical path
  (13A); 10-min pre-destructive freshness gate (14A); no sheet-render caching
  (16A — measured as noise).

## Open questions — all closed

Answered by what shipped; see the Status block at the top of this file.

1. ~~Export duplicates multi-collection files per folder, or a single `_assets/`
   pool + links?~~ **Duplicated per folder**, one canonical asset in the manifest.
2. ~~Zip wrapper in v1 or folder-tree only?~~ **Folder tree only.**
3. ~~H5 backup cadence?~~ **Manual + on-launch-if-stale**, as a visible
   preference (`BackupCadence`).

## Still to come from elsewhere

[023](feature-todo/023-archive-and-second-library.md)'s `archived_at` adds one
optional field to the manifest — a restore that dropped it would silently
un-archive the user's whole shelf. That is 023's A4, tracked there.

# 326 — A Backup You Can Come Back From (008 · H5c)

301 taught the app to copy a library into a folder. This teaches it to come
back: choose a backup in that folder, copy its images into the live library,
and let the backup's database **become a snapshot** so the restore path that has
been shipping since H3 does the swap. There is no second swap path, and there is
no new schema — the library is still at v18.

## Summary

- **`BackupCatalog` + `BackupSource`** (new, AtelierIngestion) — restore
  **discovers**, it does not look up. See "Whose id names the folder" below;
  this is the single most important decision in the change.
- **`RestoreRunner`** (new, AtelierIngestion) — refuse, then blobs, then the
  database as a snapshot. Ends by handing a `SnapshotFile`-named URL to the
  caller and stopping.
- **`MediaBackupper.missingFiles()` + `copyFiles(_:)`** — the copier is now
  direction-agnostic. Backup drives the diff from the **database**
  (`missing(from:)` over referenced `BlobRef`s); restore drives it from the
  **file tree**. One copy loop, two diffs; `copy(_ refs:)` now maps to
  `copyFiles` so the mime→extension derivation happens in exactly one place.
- **`LibraryIdentity.adopt(_:root:)`** (new) — the deliberate, restore-only
  overwrite of the id file.
- **`SnapshotManager.applyPendingRestore` now returns `Bool`**, plus
  `stageIdentityAdoption(_:)` / `applyPendingIdentityAdoption(…)`.
- **`RestoreController`** (new) — the `BackupController` shape for the fourth
  time: `@Published progress`, `CancelFlag`, work off the main actor, state
  `@MainActor`, and the cancel flag read **before** any error is classified.
- **`RestoreBackupSheet`** (new) + a restore row in Settings ▸ Backup, and
  restore prose on `BackupTarget` (AppKit-free and fully tested, per H4's split).

## Whose id names the backup folder

A backup writes to `<target>/<library-id>/`, where the id comes from the *live*
library. Restore cannot do the mirror of that, and getting it wrong makes the
whole feature useless: the case restore exists for is "my Mac died", and the
replacement Mac's library mints a **fresh** id that has never appeared in the
backup folder. Looking under the local id would report an empty folder while the
user's entire library sat one directory away.

So restore reads the folder and lists what is in it. `BackupCatalog.sources(in:)`
is one shallow directory read: a child directory whose name is a well-formed
identity, holding both a `library.sqlite` **and** a parseable
`backup-manifest.json`. The manifest requirement is not cosmetic — `BackupRunner`
writes it last, so its absence means that run never finished, and offering that
directory would be offering an unknown fraction of a library as though it were
the whole thing.

**And the restored library adopts the backup's id.** Without that, a library
restored from backup `A` keeps its own id, backs up to a fresh empty folder
beside `A`, re-copies every blob, and leaves `A` stranded and never updated
again — the same orphaning `LibraryIdentity`'s header warns about, arrived at
from the other direction. The library now holds `A`'s database; it *is* `A`.

Adoption is **deferred**, which is the subtle half. Writing the new id at
staging time would point this library's backups at `<target>/A/` while it still
held its own database — a user who staged a restore and then pressed "Back Up
Now" instead of relaunching would overwrite the very backup they were about to
restore from. So staging writes a `.pending-library-id` request beside
`.pending-restore`, and bootstrap adopts only when `applyPendingRestore` reports
that a restore **actually landed**. The request is consumed either way, so it
can never fire on some unrelated later restore. Belt and braces: "Back Up Now"
is disabled while any restore is pending, since the database about to be
discarded is not the one to push off-device.

## Through the one shipped seam

`RestoreRunner` never installs anything. It copies the backup's `library.sqlite`
into the live `snapshots/` directory under a **dot-prefixed staging name**,
integrity-checks it *there*, and only then renames it to a valid
`SnapshotFile.makeURL(in:reason:date:)` name. Between landing and passing, the
file is unparseable as a snapshot and therefore invisible to
`SnapshotManager.list()` — a half-copied database can never be offered as
something to replace a library with.

From that point it is an ordinary snapshot: `stageRestore` → `.pending-restore`
→ relaunch → `applyPendingRestore`, atomic and rollback-safe, with the live
database set aside rather than deleted. The post-restore blob reconcile
(`.just-restored`) then reports divergence for free, exactly as it does for a
snapshot restore.

Two naming details, both about retention. The snapshot is `.manual` at **today's**
date, not the backup's: retention prunes by date, and a three-month-old backup
named with its own timestamp would arrive already outside the rolling window and
could be pruned between staging and the relaunch that applies it — turning a
restore into a silent no-op. The file really was created now; the *backup's* date
is what the confirmation dialog names.

## What restore copies, and what it refuses to touch

The reverse diff is the backup's **whole blob tree**, minus what the live library
already has. That is a superset of what the restored database will reference,
because a backup keeps blobs the library later deleted (deletes deliberately do
not propagate). Copying the superset is the safe direction: a blob too many is
reclaimed by a later orphan GC, a blob too few is an item that renders empty
forever.

Reading the backup's database to narrow that set was considered and rejected:
`LibraryDatabase.init` **migrates** what it opens, so a restore that read the
backup would rewrite the artifact it exists to protect.

Restore adds and never removes — pruning in this direction would delete media
captured since the backup was taken. Pinned by a test in both directions.

Two version refusals, checked **before** anything is copied: a `manifest_version`
newer than this build, and a `schema_version` newer than
`AppServices.schemaVersion`. An unparseable version on either side is *not* a
refusal — the rule is "newer than me", and "I can't tell" is not evidence of
that; refusing on it would brick the one feature people reach for when
everything else has already gone wrong.

## Files changed

**AtelierIngestion**

- `Backup/BackupCatalog.swift` (new) — `BackupSource`, `BackupCatalog.sources(in:)`.
- `Backup/RestoreRunner.swift` (new) — the run, `RestoreError`, the pure
  `refusal(for:schemaVersion:)`, `RestoreRunResult`.
- `Backup/MediaBackupper.swift` — `BlobFile`, `missingFiles()`, `copyFiles(_:)`;
  `copy(_ refs:)` now delegates.
- `Backup/LibraryIdentity.swift` — `adopt(_:root:)`.
- `Backup/BackupLayout.swift` — `Equatable`.

**AtelierRefs**

- `RestoreController.swift` (new) — `RestoreRunSummary`, scan + run + cancel.
- `RestoreBackupSheet.swift` (new) — the candidate list and its confirmation.
- `SnapshotManager.swift` — `applyPendingRestore` returns `Bool`;
  `stageIdentityAdoption`, `applyPendingIdentityAdoption`.
- `BackupTarget.swift` — restore messages, status line, confirmation, explainer.
- `IngestionModel.swift` — `restore`, `showRestoreBackups`, `hasPendingRestore`,
  `canRestoreBackup`, `beginRestoreFromBackup`, `restoreFromBackup(_:)`,
  the staging hand-off, the bootstrap adoption call, and the `canRunBackup` guard.
- `SettingsView.swift`, `AtelierRefsApp.swift` — the restore row and the wiring.

**Tests** — `RestoreRunnerTests` (incl. `BackupCatalogTests`,
`LibraryIdentityAdoptTests`), the reverse-diff matrix in `MediaBackupperTests`,
`RestoreControllerTests` (incl. `RestoreIdentityAdoptionTests`),
`RestoreCopyTests`.

## Migration notes

**None.** No schema change (still v18), no defaults key added or renamed, no
on-disk format changed. `.pending-library-id` is a new marker inside
`snapshots/`, written only by a restore and consumed by the next launch; a build
without this change simply ignores it.

One source-level rename to avoid an overload ambiguity at the call site:
`RestoreError.databaseCopyFailed` is spelled `databaseUnreadable`, so
`BackupTarget.message(for: .databaseCopyFailed)` still unambiguously means
`BackupRunner.RunError`.

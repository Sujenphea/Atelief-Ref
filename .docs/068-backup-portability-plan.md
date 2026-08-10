# 068 — Backup H4–H7 Plan: Off-Device Backup + Portability Archive

> The remaining half of [081](081-backup-plan.md), planned against the
> code as it actually stands after the 2026-07-31 backup-hardening pass
> (changelog 290). H1–H3 (snapshots, TM hardening, staged restore) are shipped;
> this doc plans **H4–H5** (back up the library to a user-chosen folder) and
> **H6–H7** (a portable archive that exports and re-imports).
>
> Grounded in a reconnaissance pass over `MediaStore`, `AppServices`,
> `SnapshotManager`, and the app's picker / progress / toast conventions —
> API-level specifics are cited inline so implementation doesn't re-derive them.

## Naming decision (settled here, before any code)

The word **export** is already taken twice in this codebase, in the *rendering*
sense: the `AtelierExport` package (052's moodboard/contact-sheet renderer, a
deliberate zero-dependency island), and the app's `ExportController`,
`MoodboardExport`, `ContactSheetExport`, `AssetExport`. Adding a third,
unrelated "export" (the data round-trip) would make the term meaningless.

**This feature is the library _archive_.** Verbs: *Archive Library…* /
*Import Archive…*. Types: `LibraryArchive*`. `AssetExport` (the filename
sanitizer) keeps its name and is **reused, not forked** — its header comment
already anticipates exactly this ("one export naming rule, not two").

## Shared foundations (build once, both halves consume)

> **Status: F1–F3, H4, H5, H6 and H7 are all BUILT** — 008 is complete. The
> sections below describe them as planned; each carries an "As built" note
> recording where the shipped code departed from the plan and why.

### F1 — `BlobRef`: the `(hash, mimeType)` pair as a Core read

`referencedBlobHashes()` (`AppServices.swift:1384`) returns hashes only, but
every file-level operation needs the **extension** too, which is derived from
the mime type (`ImageMetadata.fileExtension(forMIMEType:)`). The delete side
already solved this with `OrphanedBlob { blobHash, mimeType }`
(`OrphanedBlob.swift:20`) crossing the Core→Ingestion seam.

**As built:** `OrphanedBlob` was **renamed to `BlobRef`** rather than joined by a
second identical struct — "a blob hash plus the mime that yields its file
extension" is one concept, and the *guarantee* (reclaimable vs live) is carried
by the API that returns it, not by the type. `deleteAssets` still returns them;
`reap(_ orphans:)` keeps its parameter name so the danger signal survives.

`AppServices.referencedBlobs() async throws -> [BlobRef]` groups by hash so a
shared blob is emitted once, and settles two nuances in SQL rather than leaving
them to chance: a NULL mime becomes `""` (matching the dotless path `MediaStore`
already writes for an unresolvable mime), and a hash carrying conflicting mimes
resolves via `MIN` so a backup diff is reproducible run-to-run. A caller finding
no file at the derived extension must report a miss, not crash — the bytes carry
whichever extension ingest wrote first. `referencedBlobHashes()` stays for the
GC path that genuinely only needs hashes.

**Watch the extension trap:** `UTType(mimeType: "image/jpeg").preferredFilenameExtension`
is `"jpeg"`, **not** `"jpg"`; thumbnails are separately hardcoded `"jpg"`
(`MediaReaper.swift:84`). An unresolvable mime yields `""` and a **dotless**
blob path. Any destination path math must use the same
`ImageMetadata.fileExtension` call rather than assuming a mapping.

### F2 — `FolderAccess`: the sandbox seam (H4)

A protocol wrapping *pick a folder → persist a bookmark → resolve it → run
inside a security scope*, with a real implementation and a test double. Every
piece of backup logic takes a `FolderAccess`, so **no test needs the sandbox**:

```swift
protocol FolderAccess: Sendable {
    func resolve() throws -> URL              // stale bookmark → throws .staleBookmark
    func withAccess<T>(_ body: (URL) throws -> T) throws -> T
}
```

**As built:** two protocols, each with an immediate test consumer —
`FolderAccess` (what H5's engine depends on; `DirectFolderAccess` lets its tests
use a plain temp dir with no bookmarks at all) and `BookmarkVault` (what
`StoredFolderAccess` depends on, so persistence/staleness/error logic is tested
without the sandbox, which cannot produce a powerbox-granted URL in-process).
`SecurityScopedBookmarkVault` is therefore compile-only + manual by design.
Behaviours pinned by tests: a failed bookmark persists **nothing** (never a
half-chosen target), and an unresolvable bookmark is **kept**, not forgotten —
an unplugged drive must mean "plug it back in", not "set up your backup again".
The entitlement is in place, with a matching `verify-release.sh` assertion.

The picker (H4): `NSOpenPanel` with `canChooseDirectories = true`,
`canCreateDirectories = true`, `canChooseFiles = false`, cloning the
sheet-if-keyWindow-else-modal idiom from `ImportFilesPanel.swift:38`; bookmark
blob in `UserDefaults` under `"AtelierBackupFolderBookmark"` (the ad-hoc
`Atelier…` + `nonisolated static let` convention, per `NavModel.swift:110`);
every run wrapped in `startAccessingSecurityScopedResource()` / `stop…` via
`defer`.

**Entitlement**: add `com.apple.security.files.bookmarks.app-scope`.
`files.user-selected.read-write` is **already present** — the original 008 plan
assumed it wasn't. Entitlements are not unit-testable here (the test host is
sandboxed and can't read the source plist); they're verified in
`scripts/verify-release.sh` **check 5** — so H4 must add a `grep` clause there
alongside the existing app-sandbox / network.server / mach-lookup assertions.

### F3 — `runBounded` is trapped in `IngestCoordinator`

`IngestCoordinator.runBounded` (`IngestCoordinator.swift:33`) is exactly the
bounded-concurrency + cancellation primitive a blob copier wants — task group
primed with `maxConcurrent`, strict one-in-one-out, `Task.isCancelled` stops
launching new work, index-aligned results — but its signature is **hardcoded to
`[IngestInput]`**. Its `ProgressReporter` actor (:133) that serializes
completion counts to strictly 1…total is equally reusable.

**As built:** both moved to `BoundedWork.swift`, generalized over
`Element: Sendable` and made `public` so the app target can use them;
`IngestCoordinator` now consumes them, so its existing suite guards the
refactor. One caveat documented at the definition: `runBounded` reads the
*surrounding* task's cancellation, and `Task.detached` does NOT inherit it — a
detached backup run must thread its own flag (the `CancelFlag` precedent in
`ExportController`).

## H4 — Folder target (S)

1. Entitlement + `verify-release.sh` clause.
2. `FolderAccess` protocol + `SecurityScopedFolder` implementation + bookmark
   persistence (stale/missing/moved → typed error, never a crash).
3. `BackupTargetPicker` (the `NSOpenPanel` clone) + a **Backup** section in
   `SettingsView` beside `librarySection` — showing the target path, "Choose
   Folder…", "Back Up Now", last-run status.

**State placement:** `SettingsView` used to be rendered **twice** — as the ⌘,
`Settings` scene and as a sidebar pane — which would have forked backup progress
into two disagreeing copies. Changelog 297 collapsed that to one surface (the ⌘,
window; the sidebar gear now *opens* it), so the duplication is gone.

The rule still stands for a different reason: the Settings **window can be closed
and reopened mid-backup**, and `@State` on `SettingsView` would reset with it —
showing a fresh "Choose Folder…" over a copy that is still running. Backup
progress therefore belongs on `IngestionModel`, or on a `@StateObject` at
`ContentView` injected via `.environmentObject` (the `ExportController`
precedent), **never** `@State` on `SettingsView`.

Capture-token UI in that view now comes from the shared `CaptureTokenViews.swift`
pieces (`CaptureCopy` + the three small views). The Backup section should follow
the same split if it grows a second surface: shared **facts and rules** in a
testable enum, layout left to each surface.

**Tests:** bookmark round-trip and staleness against an injected defaults +
fake resolver; picker glue is compile-only + manual (repo convention).

**As built (`299-backup-folder-target`):** steps 1 and 2 shipped with F2. Step 3 shipped as
`BackupFolderPanel` (the picker) + `BackupTarget` (rules and words, AppKit-free
and fully tested) + a **Backup** section in `SettingsView`, with the target state
on `IngestionModel` per the placement rule above.

Two departures from the sketch:

- **"Back Up Now" and last-run status are NOT in H4.** Both need H5's engine, and
  an inert button — or a status line about runs that cannot happen — is worse
  than an absent one. The section is shaped so both drop in without rework.
- **A containment guard was added**, unplanned but belonging to *choosing*
  rather than running: a target that is the library, or inside it, is rejected.
  Compared by path component after symlink resolution — a string-prefix check
  would reject `…/Atelier2` as being inside `…/Atelier`. The library's *parent*
  is allowed, since backups land in `<target>/<library-id>/` and never recurse.

H5 therefore starts from: a resolved, vetted `FolderAccess` and a Settings
section with two empty slots in it.

## H5 — Incremental blob backup + restore (M)

### Destination layout

```
<target>/<library-id>/          ← namespaced now; multi-library is deferred, not precluded
  blobs/ab/cd/<hash>.<ext>      ← identical shard layout to the live library
  library.sqlite                ← VACUUM INTO snapshot, self-contained
  backup-manifest.json          ← schema/app version, library id, run timestamp,
                                  blob count + total bytes, DB size
```

Deliberately **excluded**: `thumbnails/` and `cache/` (regenerable — and already
`isExcludedFromBackup` locally), and `snapshots/` (recovery artifacts of the
*source* machine; copying them multiplies the footprint for no recovery value
the backup's own DB copy doesn't already provide).

### The copy engine — `MediaBackupper`

The symmetric sibling of `MediaReaper` (which is precisely "a `Sendable` struct
wrapping `MediaStore` that sweeps the whole store, best-effort per file"):

- **Diff is a pure function** — `missingHashes(live:destination:) -> [BlobRef]`,
  unit-tested over empty / partial / identical / extra-at-destination.
- **Destination path math comes free**: construct
  `MediaStore(root: destinationRoot)` and call `blobURL(hash:fileExtension:)`.
  Same shard scheme, zero duplicated path logic.
- **Copy must stage + rename**, mirroring `MediaStore.atomicWrite` (:273): copy
  to `<dest>/cache/<uuid>`, then `moveItem` into the sharded path. This is what
  makes the *next* run's "destination file exists ⇒ already copied" check sound
  — the same invariant (A2: an existing blob file is complete) the reaper and
  ingest pipeline already rely on. A plain `copyItem` to the final path would
  make an interrupted run indistinguishable from a complete one.
- **Progress + cancel** via F3's generalized `runBounded` + `ProgressReporter`,
  surfaced with the `ExportController` shape: `@Published progress: Double`,
  `CancelFlag` (`ExportController.swift:174` — needed because `Task.detached`
  does *not* inherit cancellation), and a `Report` with a monotonic `seq` so
  two identical back-to-back reports still trip `.onChange`.

### DB copy

`AppServices.snapshot(to:)` **refuses to overwrite** (`AppServices.swift:71`),
so each run writes `library.sqlite.new` then renames over the previous — never
delete the old copy before the new one is complete and `isHealthy`.

### Verification

`isHealthy(databaseFileAt:)` on the copied DB, plus a **sampled re-hash** of
copied blobs (filename *is* the hash, so verification is self-describing). Cap
the sample: on an **iCloud Drive destination the files may be dataless**, so
enumeration stays metadata-cheap but re-hashing forces a download — the sample
size is a user-visible cost, not a free check. Full-verify stays an explicit,
separate action.

### Restore — through the ONE shipped seam

Per review decision 4A, backup restore does **not** get its own swap path:

1. Copy missing blobs *back* into the live `blobs/` (content-addressed and
   idempotent — safe with the app running, since existing files are complete).
2. Copy the backup's `library.sqlite` into the live `snapshots/` directory under
   a valid `SnapshotFile` name (`SnapshotFile.makeURL(in:reason:date:)`).
3. Call the existing `stageRestore` → marker → relaunch →
   `applyPendingRestore` flow, which is already atomic, rollback-safe, and
   covered by the failure-path suite added in changelog 290.

The backup's DB thus *becomes* a snapshot the moment it lands locally — one
restore mechanism, one set of tests, and the post-restore blob reconcile (3A)
reports divergence for free.

**Tests:** pure diff matrix; A→folder→B round-trip (rows *and* blob bytes
equal); interrupted-run resume leaves no partial file and completes on re-run;
corrupted destination blob → verify fails; destination-full → fails loudly
without pruning what's already there; stale bookmark → typed error; all
sandbox/panel glue behind `FolderAccess`.

**As built (`300-backup-copy-engine`) — H5a, the engine.** `LibraryIdentity`,
`BackupLayout`, `BackupManifest`, `MediaBackupper`, `BackupRunner` in
`AtelierIngestion/Backup/`, plus `MediaStore.storeBlobFile(copyingFrom:…)` and a
public `AppServices.schemaVersion`. 58 tests. Departures worth carrying forward:

- **Library identity is a FILE at the Library root, not a DB column.** Restoring
  a snapshot replaces `library.sqlite` wholesale, so an id inside it would come
  back as the snapshot's id — the same library would start writing to a
  different backup folder, orphaning everything already copied. 16 lowercase hex
  chars, strictly validated because it is interpolated into a path.
- **The sampled re-hash verification is NOT in H5a.** The database copy is
  integrity-checked before it replaces the previous one, which is the check that
  protects against the realistic failure (a destination filling up mid-copy).
  Re-hashing blobs is a separate, explicitly-priced action — on a synced
  destination it forces a download — and it belongs with the UI that can show
  its cost. Deferred to H5b or later, not dropped.
- **Deletes deliberately do not propagate.** A blob removed from the library
  stays in the backup; pruning would make an accidental delete propagate
  off-device, which is the case people restore *from*. Pinned by a test.

**As built (`301-backup-run-now`) — H5b, the app wiring.** `BackupController` (the
`ExportController` shape), `BackupRunSummary` + `BackupSummaryStore`, run-failure
and status words on `BackupTarget`, and the Settings run row. 33 tests. Two
things worth carrying into H6/H7:

- **`FolderAccess` now has an async `withAccess`.** A security scope held only
  for a synchronous call is torn down at the first `await`; any long export or
  import into a user-chosen folder needs the async bracket, not the sync one.
  The protocol declares `resolve`/`beginAccess`/`endAccess` and an extension
  supplies both brackets, so the release `defer` exists once.
- **A cancelled run must not be classified as a failure.** Cancelling tears down
  in-flight work, which throws; the controller checks the cancel flag *before*
  it classifies any error. Any future long-running job needs the same order.

**As built (`326-a-backup-you-can-come-back-from`) — H5c, restore.**
`BackupCatalog`/`BackupSource` and `RestoreRunner` in `AtelierIngestion/Backup/`,
`MediaBackupper` generalized to copy in either direction,
`LibraryIdentity.adopt`, plus `RestoreController`, `RestoreBackupSheet`, the
restore prose on `BackupTarget`, and a restore row in Settings ▸ Backup. 62
tests. No schema change (v18 stands). Four things worth carrying into H6/H7:

- **Restore DISCOVERS the backup; it does not look it up by the local id.** The
  case restore exists for is "my Mac died", and the replacement Mac's library
  mints a *fresh* `LibraryIdentity` that has never appeared in the backup folder
  — a lookup would report an empty folder while the whole library sat one
  directory away. `BackupCatalog.sources(in:)` is one shallow directory read;
  a child counts only if its name is a well-formed identity AND it holds both a
  database and a parseable manifest (the manifest is `BackupRunner`'s commit
  record, so its absence means that run never finished).
- **The restored library ADOPTS the backup's id, but only after the restore
  actually lands.** Keeping its own id would send its next backup to a fresh
  empty folder beside the one it was restored from — every blob re-copied, the
  real backup stranded — which is `LibraryIdentity`'s own warning reached from
  the other direction. Adopting *eagerly* is worse: a user who staged a restore
  and then pressed "Back Up Now" would overwrite the backup they were about to
  restore from. So staging writes a `.pending-library-id` request, bootstrap
  adopts only when `applyPendingRestore` (now returning `Bool`) reports a real
  swap, and the request is consumed either way so it cannot fire on a later,
  unrelated restore. "Back Up Now" is additionally disabled while any restore
  is pending.
- **The database copy is invisible until it is proven.** It lands in the live
  `snapshots/` under a dot-prefixed staging name — deliberately unparseable by
  `SnapshotFile` — is integrity-checked *there*, and only then renames into a
  `SnapshotFile.makeURL` name. It is named `.manual` at TODAY's date, not the
  backup's: retention prunes by date, so an old backup named with its own
  timestamp could be pruned between staging and the relaunch that applies it,
  turning a restore into a silent no-op.
- **The reverse diff reads the FILE TREE, never the backup's database.**
  `LibraryDatabase.init` migrates what it opens, so reading the backup to narrow
  the copy set would rewrite the artifact restore exists to protect. The tree is
  a superset of what the restored DB references (deletes don't propagate, so a
  backup holds blobs the library dropped) and that is the safe direction: a blob
  too many is reclaimed by a later orphan GC, a blob too few renders empty
  forever. Restore adds and never removes — pruning here would delete media
  captured since the backup. Pinned by tests in both directions.

Two version refusals are checked before anything is copied (`manifest_version`
and `schema_version` newer than this build), and an *unparseable* version on
either side is deliberately NOT a refusal — the rule is "newer than me", and "I
can't tell" is not evidence of it. H6/H7's `manifest_version` refusal should
follow the same shape.

**As built (`327-a-backup-that-runs-itself-and-proves-itself`) — H5d, cadence +
sampled verification.** `BackupCadence`/`BackupCadenceStore`,
`BackupController.backUpIfStale` + `isStale`, `BackupVerifier` +
`BackupVerifyResult` in `AtelierIngestion/Backup/`, `BackupVerifyController`, and
an "Automatically" picker plus a check row in Settings ▸ Backup. 43 tests. No
schema change (v18 stands); one new per-library key,
`library.<id>.backupCadence`. Four things worth carrying into H6/H7:

- **Only a run that LANDED resets the staleness clock.** A failed or cancelled
  run leaves the destination exactly as stale as it was, so counting either as a
  backup would buy a whole cadence period of silence for a backup that never
  happened — one press of Stop, and the copy quietly goes a week out of date. An
  *incomplete* run does reset it: it finished and installed a verified database,
  and what it could not copy was a blob missing at the SOURCE, which re-running
  cannot conjure back. Treating that as stale would attempt a full backup on
  every launch forever over a fault the status line already reports in words.
  The clock is injected the way `SnapshotManager`'s is, so the boundary is a
  decision about a `Date` rather than about wall-clock time.
- **An unreachable target is a SKIP, not a failure — but only on the automatic
  path.** An unplugged external drive is the normal state of a backup disk, and
  "Last backup failed" at every launch would train the user to ignore the one
  time it means something. So `backUpIfStale` resolves the bookmark first and
  returns silently if it can't, while "Back Up Now" — which a human just pressed
  — still reports the reason. Any future unattended job needs the same split
  between "nobody asked, so stay quiet" and "you asked, so here's why not".
  The pending-restore guard is the reverse case: it matters MORE unattended,
  because an automatic run would overwrite the backup the user is one relaunch
  away from restoring and nobody would have caused it.
- **The sample is deterministic, and striding is what makes it mean anything.**
  Sorted by hash, then taken at a fixed stride from a seed-chosen offset. Taking
  the first N would re-verify one shard directory forever while implying the
  whole backup — a check that passes because it never looks where the damage is
  is worse than no check, because it is believed. The seed rotates the offset so
  successive runs drift across the tree while any single (tree, limit, seed) is
  exactly reproducible; a random pick would be untestable here and unanswerable
  in a support conversation. The cap is a COUNT rather than a byte budget, so
  the sample size can't depend on which files happened to be picked; the bytes
  read are reported afterwards, which is where the cost belongs.
- **Verification reports; it never repairs.** `BackupVerifier` contains no
  delete, move, or rewrite, and that is a refusal rather than an omission: a
  file whose bytes disagree with its name is still the only copy of something at
  a destination the user restores FROM, and a transient read error on a network
  volume looks exactly like corruption. Unreadable is therefore reported apart
  from mismatched — the bytes were never seen, so calling them wrong would be a
  guess dressed as a measurement — and every sentence about a finding says
  outright that nothing was deleted, because that is the first question it
  provokes. H6/H7 should assume the same: an integrity check on a user's only
  copy earns the right to complain, never the right to prune.

Cadence defaults to **manual** (user, 2026-08-03). Daily-by-default was built
first, on the H3 daily-snapshot precedent, and rejected for the reason that
precedent doesn't carry: a snapshot stays inside the library, while a backup
copies it somewhere the user chose, and an install that already has a folder
chosen must not quietly start doing that because it was updated. The two
fallbacks are therefore deliberately different — **absent ⇒ manual**, but an
**unreadable stored value ⇒ daily**. "Never asked" and "asked in words this
build doesn't know" are opposite facts, and degrading the second to `manual`
would silently stop the backups of anyone who ran a newer build once.

H4–H5 are therefore complete, and H6 and H7 shipped after them (see their
"As built" notes below). The whole 008 line is done; [016]'s importers now have
the replay layer they were waiting on.

## H6 — Archive export (M)

A human-browsable folder tree plus one machine-readable manifest:

```
<archive>/
  manifest.json                        ← the contract; the whole graph
  Collections/<collection path…>/<title-or-source>-<shorthash>.<ext>
```

- **Filenames reuse `AssetExport.filename(base:blobHash:ext:)` verbatim** —
  same sanitizer, same 60-char cap, same hash suffix, one shared test suite
  (`AssetExportTests`). Two additions the archive needs that drag-out didn't:
  a **collision suffix** (an 8-hex-char prefix is not a uniqueness guarantee
  across a whole library, and macOS is case-insensitive: `Hero-ab12cd34.png`
  and `hero-ab12cd34.png` collide), and **path-length clamping** for deeply
  nested collection trees.
- **Multi-collection assets are copied into each folder** (browsability is the
  point of the tree) while the manifest records the single canonical asset — so
  re-import yields one asset, N memberships, not N duplicates.
- **`manifest.json` is the contract**, versioned with its own
  `manifest_version` *and* the DB `schema_version` it was written from. It
  captures the full graph: sources/provenance, assets, tags, collections with
  nesting, memberships with manual order, timestamps, favourites. Derived data
  (`asset_analysis` — OCR/colors/phash/embeddings) is **excluded**: it is
  recomputable by definition, and including it would freeze an
  `analyzer_version` into a portability contract.
- Streaming write with progress + cancel (same `ExportController` shape); never
  hold the library in memory.

**Tests:** golden-file manifest serialization (the contract must break loudly
when the shape changes); the filename matrix stays in `AssetExportTests`;
collision and case-insensitivity cases; a deep-nesting path-length case; empty
library and empty collection.

**As built (`328-a-library-you-can-take-with-you`) — H6, the archive writer.**
`LibraryArchive` (the contract: `ArchiveManifest`, `ArchiveLayout`,
`ArchiveRefusal`), `LibraryArchiveWriter`, `ArchiveExportController` +
`ArchiveRunSummary` + `ArchiveCopy`, `ArchiveFolderPanel`, and an **Archive**
section in Settings. 58 tests. No schema change (v18 stands), no new entitlement
— a save-panel grant lasts the process, which is longer than the run. Folder tree
only; no zip wrapper (open question 1, settled as recommended). Six things H7
must build on:

- **The manifest is `manifest_version` 1 and is fully replayable by design.**
  Top level: `manifest_version`, `schema_version`, `app_version`, `exported_at`,
  `sources[]`, `assets[]`, `collections[]`. Each collection carries its own
  `items[]` (the memberships, in manual order) plus a `path` — where its copies
  were written — and every asset appears in `assets[]` exactly ONCE with its
  `blob_hash`, `payload` and `dedup_key`, however many folders hold its bytes.
  Everything in it maps onto a shipped public writer: sources+assets →
  `ingest` / `ingestContent`, `collections` → `createCollection`, `items` →
  `addAssets` + `setGridOrder` (+ `setCanvasPlacement` for the canvas columns),
  per-asset `tags: [{name, source}]` → `applyTag`.
- **Provenance is verbatim, and that is the round-trip's correctness.** 18A dedup
  matches on `original_url` when one exists, else `platform`, so a dropped or
  normalized source field forks a second asset over the same bytes on re-import.
  `original_url` / `author_handle` / `author_name` / `title` / `platform` /
  `captured_at` / the whole `raw_metadata` document are copied unchanged, pinned
  by a test that names them.
- **Three deliberate exclusions and one absence.** `asset_analysis` and
  `asset_embedding` are out (recomputable, and including them would freeze an
  `analyzer_version` into a portability contract). A tag with no asset is out —
  no public writer can recreate one, and keeping the contract 100% replayable is
  worth more than the edge case. Spaces / saved searches / jobs are out: not in
  this plan's graph and not representable in a collection tree — a named gap, not
  an oversight. And **favourites do not exist in schema v18**; the plan lists
  them, but there is no column, tag convention or flag to carry.
  *(Superseded 2026-08-03 — see “Amendment: favourites now ride the manifest”
  at the end of this document. Schema v19 adds `asset.is_favorite`, and the
  manifest carries it.)*
- **The tree duplicates, the manifest does not — and the FILENAME ALLOCATOR IS
  KEYED BY DESTINATION FOLDER.** That last detail is what makes the path rule
  below safe: two collections that ever resolve to one folder still cannot
  collide on a filename.
- **Path budget, not depth limit.** 768 bytes of archive-relative path, 256 of
  them reserved for the filename (`PATH_MAX` is 1024, a 60-*character* name is up
  to 240 *bytes* of emoji, and the archive root is the user's and unbounded). A
  folder that would overrun is relocated to the top of `Collections/` with its
  id's first 8 hex appended; relocation cascades gently, so a pathological tree
  becomes several shallow trees rather than one flat pile. Safe because the tree
  is a PRESENTATION of the graph — the manifest still carries every real
  `parent_collection_id`, so H7 must read `parent_collection_id`, never `path`.
  Paths can legitimately repeat.
- **`manifest.json` is written LAST and atomically** — the export's commit
  record, exactly as `BackupRunner`'s manifest is a backup's, which is why
  `BackupCatalog` can treat its absence as "that run never finished". A cancelled
  or failed archive is therefore a folder of images with no manifest: visibly
  incomplete rather than plausibly whole. The cancel flag is read BEFORE any
  error is classified (H5b/H5c's rule, third job to inherit it).

`ArchiveManifest.refusal(for:schemaVersion:)` already implements H7's version
rule in H5c's shape — "newer than me" on both axes, an unparseable version on
either side deliberately NOT a refusal. H7 calls it; it does not re-derive it.

One incidental change outside the feature: `AssetExport`'s `baseName` /
`sanitize` / `filename` / `exportItem` are now `nonisolated`. They were always
pure — the app target is `MainActor` by default and the writer names thousands
of files from a detached task, so the annotation only says to the compiler what
the header already said to the reader. `dragProvider` stays main-actor.

## H7 — Archive import + the shared replay layer (M)

The importer is deliberately **two pieces**, because [016]'s competitor
importers (Eagle, Raindrop, Pinterest) consume the second one:

1. **`parse(archive) -> [ImportPlan]`** — pure, fixture-tested. Archive-specific.
2. **The replay layer** — walks `[ImportPlan]` through the existing public
   writers (`createCollection` `:581`, `ingest` `:811`, `applyTag` `:2521`,
   `addAssets` `:1094`, `setGridOrder` `:1044`). Every invariant, validation,
   and content-hash dedup comes free because nothing bypasses the funnel.
   **This layer is 016's dependency — its shape is the deliverable, not just
   the archive import.**

Semantics that must be explicit (this is the half where silence causes damage):

- **Version refusal**: a `manifest_version` newer than this build → refuse with
  a clear message. Never partially apply an unknown contract.
- **Destination is an explicit choice** — a new root collection named after the
  archive (recommended) vs merging into the existing structure. Never silently
  clobber.
- **Idempotent by content hash — but only if provenance replays verbatim.**
  `ingest` is documented idempotent on "identical bytes + provenance into the
  same collection", and its 18A dedup reuses an existing asset sharing the blob
  hash **whose source matches the incoming provenance** (`AppServices.swift:795-808`).
  So import idempotency is a property of the *manifest*, not just the pipeline:
  if the exporter drops or normalizes a source field, re-import silently forks a
  second asset over the same bytes. The round-trip test must assert asset
  *count*, not merely presence.
- **Honest reports**: N imported / N skipped with reasons / N failed — never a
  silent partial ([004]'s batch-outcome lesson, and the same standard the 8A
  work just applied to snapshot failures).
- **Import is destructive-adjacent** → it should take a pre-destructive
  snapshot first, which the shipped `snapshotBeforeDestruction()` gate already
  makes cheap.

**Tests:** full export→import round-trip over temp libraries (collections,
nesting, memberships, manual order, tags, provenance, favourites, blob bytes
all equal); import-twice idempotency; version refusal; malformed/truncated
manifest; missing blob file referenced by the manifest; unicode/emoji names;
a large-archive streaming case.

**As built (`329-an-archive-you-can-read-back-in`) — H7, the importer.**
`ImportPlan` (the replay layer's vocabulary), `ImportReplay` (`LibraryImporter`),
`LibraryArchiveReader` (`ArchiveParse` / `ArchiveReadError`),
`ArchiveImportController` + `ImportRunSummary` + `ArchiveImportCopy`,
`ArchiveFolderPanel.presentImport`, and an import row in Settings ▸ Archive.
36 tests. No schema change (v18 stands), no new entitlement — an open-panel grant
lasts the process. Built as the planned two pieces, and the split held: every
malformed case (a manifest naming an asset it doesn't ship, a truncated file, two
collections sharing one path) is a fast fixture test, because a round-trip
harness cannot produce any of them. Seven things worth carrying forward:

- **The replay layer has no private back door, and that is the deliverable.**
  Every row it creates goes through `createCollection`, `ingest` /
  `ingestContent`, `addAssets`, `applyTag`, `setName`, `setNote`, `setGridOrder`
  or `setCanvasPlacement`. So an importer cannot produce a library state the app
  could not have produced — membership uniqueness, the Unsorted invariant, name
  validation, canonical payloads and dedup keys are neither re-implemented nor
  re-breakable here. [016]'s three parsers produce `[ImportPlan]` and inherit all
  of it. An `ImportItem` is identified by a KEY, not a row, which is what makes a
  multi-collection asset arrive as one asset with N memberships.
- **The source library's Unsorted comes in as a plain folder**, deliberately not
  special-cased. Inside a new destination collection everything is an ordinary
  folder; the alternatives — dropping those untriaged assets, or merging them
  into THIS library's Unsorted — are exactly the silent drop and the silent
  clobber the destination rule exists to prevent.
- **The blob hash is COMPUTED, never taken from the manifest.** The store is
  content-addressed, so bytes filed under an unverified hash render as the wrong
  image for every future asset that hashes there, with no recovery. An archive is
  a browsable folder whose files a user can rename or replace, so its declared
  hash is a claim about a file rather than a fact about bytes. The cost is one
  streaming read of a file that was going to be copied anyway.
- **Additive on a dedup hit, never destructive.** Tags are applied however an
  asset resolved (new information, idempotent writer); `name` and `note` only to
  a NEWLY created asset, because overwriting them on a dedup hit would silently
  discard an edit the user made in this library.
- **Parse, THEN snapshot, THEN write.** A refused or unreadable archive costs
  nothing at all — no snapshot, no rows. The pre-destructive snapshot is INJECTED
  into the controller rather than reached for, so the ordering is a tested fact.
  A version refusal is its own outcome (`.refused`), not a failure: nothing
  broke, this build declined to guess. The refusal itself is H6's
  `ArchiveManifest.refusal`, called and not re-derived.
- **Idempotency was measured by COUNT, not by presence.** A source field the
  archive dropped or the reader normalized would leave every asset present on a
  second import — as a second copy. Import-twice asserts distinct-asset totals,
  and a second import of the same archive reports `newAssets == 0`.
- **Server-authoritative fields are re-minted, not restored**: ids,
  `created_at`, `view_count`, `last_viewed_at`, `dedup_key`, `search_text`. An
  import is a new library's version of the same graph; a row-for-row restore is
  H5c's job, and conflating the two would need the back door this design refuses.

**What the archive carries, now that both halves exist.** Collections with their
real nesting and descriptions; memberships with manual order and canvas
placement; assets once each with kind, dimensions, duration, download state,
name, note and payload; tags as `(name, source)`; provenance verbatim; and the
blob bytes.

It does **not** carry: `asset_analysis` / `asset_embedding` (recomputable, and
including them would freeze an `analyzer_version` into a portability contract); a
tag attached to no asset (no public writer can recreate one); and **Spaces, saved
searches and jobs** — excluded by user decision (2026-08-03), not by oversight:
they are not in this plan's graph and not representable in a collection tree.
**Favourites do not exist in schema v18** at all — this plan lists them, but
there is no column, tag convention or flag to carry, so there is nothing to
exclude either. *(Superseded 2026-08-03 by 011 · U5 — see the amendment at the
end of this document: schema v19 adds the column and the manifest carries it.)*

## Sequencing

```
F1 (BlobRef read) ─┬─→ H5 ──────────────→ H5-restore
F2 (FolderAccess) ─┤
F3 (runBounded)  ──┘
H4 (entitlement + picker + Settings pane) ──→ H5
H6 (archive export) ──→ H7 (import + replay layer) ──→ [016] importers
```

- **H4 → H5** is a hard dependency (no folder access, no backup).
- **H6 → H7** in that order so the round-trip harness has something real to
  read; H7's replay layer is what [016] waits on.
- The two halves are **independent of each other** — H6/H7 need no entitlement
  and no bookmark (a save-panel-granted URL is consumed in-process), so they can
  proceed in parallel with, or entirely before, H4/H5.

**Recommended order: F1 → F2/F3 → H4 → H5 → H6 → H7.** Off-device backup
answers the "my Mac died" failure mode, which is the one with no other mitigation
today; the archive answers data-freedom, which matters but has no deadline. If
[016]'s importers become the priority instead, invert to H6 → H7 first.

## Risks

- **Sandbox reality is the schedule risk in H5**, not the copy loop. Bookmarks
  going stale (folder renamed, volume unplugged, iCloud evicting), scope
  exhaustion on long runs, and destination volumes with different semantics
  (exFAT: no APFS clone, case-sensitivity differences) all surface only on real
  hardware. Prototype the bookmark round-trip against an external volume early
  rather than at the end.
- **iCloud dataless files** make "cheap enumeration, expensive read" the default
  at the destination — any verify or restore path must show progress and be
  cancellable, and must never assume a `fileExists` implies local bytes.
- **The archive's filename layer is where silent data confusion hides** —
  collisions and case-insensitivity produce *overwrites*, not errors. Test that
  before building the manifest.
- **Replay-layer scope creep**: it is tempting to make it general enough for all
  of [016] up front. Build it for the archive, with 016's three parsers as the
  design pressure test — not as unbuilt requirements.

## Settled decisions (user, 2026-07-31)

- **Build order: off-device first** — F1/F2/F3 → H4 → H5 → H6 → H7. Machine
  loss is the failure mode with no mitigation today; data-freedom has no
  deadline. [016]'s importers therefore wait on H7.
- **Destination keeps the latest state only** — one `library.sqlite` at the
  target, replaced per run. Blobs are content-addressed and shared; local
  snapshots already provide point-in-time recovery, so a second retention
  policy at the destination would be machinery without a matching risk.
- **Archive duplicates multi-collection assets into each folder** — browsability
  is the archive's purpose; the manifest still records one canonical asset, so
  re-import yields one asset with N memberships.
- **`runBounded` + `ProgressReporter` are generalized** rather than copied — the
  existing `IngestCoordinator` tests guard the refactor, and a third hand-rolled
  concurrency loop is the same DRY failure `SQLiteFileSet` just retired.

## Open questions

1. ~~Zip wrapper in v1, or folder-tree only?~~ **Settled: folder-tree only**,
   shipped that way in H6 — zipping a multi-GB library is a second
   progress/cancel problem for little gain, and a tree is the browsable half of
   what the archive is for.
2. Backup cadence: manual + on-launch-if-stale (recommended, mirroring the
   daily snapshot) or manual only?
3. ~~Import destination: a new root collection named after the archive
   (recommended) or merge into the existing structure?~~ **Settled: a new root
   collection named after the archive folder**, shipped that way in H7. Merging
   has no safe answer for an incoming folder that shares a name with an existing
   one, and `createCollection` already disambiguates a duplicate sibling
   Finder-style — so importing the same archive twice gives two containers rather
   than one silently clobbered.

## Amendment: favourites now ride the manifest (2026-08-03, 011 · U5)

Two sentences above say favourites do not exist in schema v18 and so are neither
carried nor excluded. That was true when H6/H7 shipped and is no longer true.
**Migration v19 adds `asset.is_favorite`** (additive, `NOT NULL DEFAULT 0`, no
back-fill), and the archive carries it end to end:

- `ArchiveManifest.AssetEntry.isFavorite` → wire key `is_favorite`, written
  unconditionally (`false` included).
- `LibraryArchiveWriter` gets it for free — `AssetEntry.init(_:tags:)` reads the
  asset.
- `LibraryArchiveReader` → `ImportItem.isFavorite`.
- `ImportReplay` applies it through `AppServices.setFavorite`.

It is carried, rather than excluded like `asset_analysis`, because it is **user
intent, not derived data**: nothing can recompute which items someone starred, so
an archive that dropped it would lose them silently on the first export after the
flag shipped — irreversibly, since the archive is often the only copy.

**`manifest_version` stays 1.** The rule this plan set is "a reader that does not
recognise the number must refuse rather than guess", and the question that
implies is: *would a reader that ignores unknown keys MISREAD this file?* For a
strictly additive optional key the answer is no — an older reader skips it and
every field it does read still means what it meant. Bumping would spend the one
signal reserved for a genuinely incompatible change (a field removed, renamed or
re-meaninged) on a change that is not one.

The "older build must not mis-read a newer archive" guarantee is carried by the
other version axis, and carried more precisely: the export records
`schema_version = "v19"`, so `ArchiveManifest.refusal` returns
`.schemaTooNew("v19")` for any build that only migrates to v18. That build
refuses the archive **whole** — it never reaches the point of silently dropping a
star it does not understand. In the other direction, a pre-v19 archive decodes
here with `is_favorite` absent, which `AssetEntry.init(from:)` reads as `false` —
the truth for a file written before the flag existed. (That hand-written
initializer is load-bearing: Swift's synthesized `Decodable` calls `decode`, not
`decodeIfPresent`, for a non-optional property, so without it every pre-v19
archive would fail to decode entirely.)

**Replay applies it like a TAG, not like `name` / `note`.** Rule 3 of
`ImportReplay` splits on whether a write can destroy something: tags are applied
whichever way an asset resolved because applying one only ever adds information.
The star is the same — and an archive's `is_favorite: false` is never replayed at
all, so importing an old archive can never unstar something the user starred in
this library.

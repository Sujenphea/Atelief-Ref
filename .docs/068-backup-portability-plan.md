# 068 — Backup H4–H7 Plan: Off-Device Backup + Portability Archive

> The remaining half of [008](feature-todo/008-backup.md), planned against the
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

> **Status: F1–F3 are BUILT** (changelog 291, branch `feat/backup-offdevice`).
> The sections below describe them as shipped; H4–H7 remain plans.

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

**State placement gotcha:** `SettingsView` is rendered **twice** — as the ⌘,
`Settings` scene (`AtelierRefsApp.swift:74`) and as a sidebar pane
(`AppShellView.swift:132`). Backup progress must therefore live on
`IngestionModel` or a `@StateObject` on `ContentView` injected via
`.environmentObject` (the `ExportController` precedent), **never** `@State` on
`SettingsView`, which would fork into two disagreeing copies.

**Tests:** bookmark round-trip and staleness against an injected defaults +
fake resolver; picker glue is compile-only + manual (repo convention).

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

1. Zip wrapper in v1, or folder-tree only (recommended — zipping a multi-GB
   library is a second progress/cancel problem for little gain)?
2. Backup cadence: manual + on-launch-if-stale (recommended, mirroring the
   daily snapshot) or manual only?
3. Import destination: a new root collection named after the archive
   (recommended) or merge into the existing structure?

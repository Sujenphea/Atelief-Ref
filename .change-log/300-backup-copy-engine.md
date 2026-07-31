# 300 — Off-device backup engine (008 · H5a)

The part that actually moves bytes: diff, copy, database, manifest. No UI yet —
that's H5b, and restore is H5c. Plan: `.docs/068-backup-portability-plan.md`.

## Summary

Five new types in `AtelierIngestion/Backup/`, plus one seam added to
`MediaStore` and one constant exposed from `AppServices`.

- **`LibraryIdentity`** — the stable name a library answers to, and the
  directory its backup lives under. See "Why a file" below.
- **`BackupLayout`** — path math for `<target>/<library-id>/`, built on
  `LibraryLayout`/`MediaStore` so the destination shards blobs through the *same
  implementation* as the live library. The incremental diff is only sound if
  both sides agree on the path for a hash; sharing the code is how they agree.
- **`BackupManifest`** — the one machine-readable file in the destination.
  Deliberately not an index of contents (the blob tree is content-addressed and
  the database copy is authoritative; a second list could only ever disagree).
  Versioned on two axes: `manifest_version` for the file's shape,
  `schema_version` for the migration the database copy came from.
- **`MediaBackupper`** — the symmetric sibling of `MediaReaper`: `Sendable`
  struct over two `MediaStore`s, best-effort per file, reporting what it
  couldn't do instead of aborting the batch. Bounded concurrency, monotonic
  progress, and cancellation come from F3's `runBounded` + `ProgressReporter`.
- **`BackupRunner`** — one run, in the order that makes every interruption
  survivable (below).

## Why the run is ordered the way it is

1. **Blobs before the database.** The database names blobs, so a database copy
   newer than the blob tree would reference files that aren't there. Copying
   blobs first means the worst an interrupted run leaves is blobs the (older)
   database doesn't mention — dead weight, not a dangling reference, and the
   next run's diff skips them.
2. **The database lands as `library.sqlite.new`, is integrity-checked *there*,
   and only then renames over.** The previous good copy is never deleted before
   its replacement is proven. The swap is `replaceItemAt` (a rename when the
   previous copy exists), so the path holds the old file or the new one and
   never nothing.
3. **The manifest is written last** — it is the run's commit record. A
   destination with no manifest is mid-flight; one with a manifest finished.

A cancelled run stops before step 2, so it never writes a manifest and never
touches the previous database copy.

## Why the library id is a file, not a column

Restoring a snapshot replaces `library.sqlite` wholesale. An id living inside
the database would come back as whatever the snapshot's id was — so the *same*
library could start writing to a different backup folder after a restore,
silently orphaning everything already copied. A file beside the database
survives every restore path untouched, which is exactly the property "which
library is this" needs.

The id is 16 lowercase hex characters and validated strictly on read, because it
becomes a **path component** under a folder the user chose: the rule rules out
traversal, separators, whitespace, and — since macOS filesystems are
case-insensitive by default — two ids differing only in case that would collide
into one directory. A malformed id file is a hard error rather than an occasion
to mint a replacement: re-minting would strand every blob already copied and
restart the whole backup in a new folder, with no signal but the folder quietly
doubling in size.

## Two things found by writing the tests

- **The manifest didn't survive its own round-trip.** ISO-8601 without
  fractional seconds is what makes the file readable, and it means a `Date()`
  isn't equal to itself after a write and a read — so every "is this still the
  backup I wrote?" comparison would have been quietly false. The initializer now
  truncates to whole seconds, so the in-memory value *is* the on-disk value.
- **`Data.write(options:)` can't be both `.atomic` and `.withoutOverwriting`** —
  atomic writes a temp file and renames it into place, which overwrites. The id
  file uses exclusivity alone; that is the property that matters there.

## `MediaStore.storeBlobFile(copyingFrom:…)`

Copying a blob through `Data` would put a whole file in RAM — fine for a JPEG,
not for the videos the library also ingests. The new entry point copies
file-to-file, and `atomicWrite` and it now share one `atomicInstall` body, so
the stage-then-rename sequence and the A2 guarantee it upholds ("a blob file
that exists is complete") are stated once. That guarantee is what makes the
incremental diff safe: "the destination already has it" has to mean "has it in
full", or an interrupted run would leave a truncated file every future run
skips.

`atomicInstall` also now cleans up after a staging failure — a copy that runs
out of space mid-stream used to be able to leave a partial temp file in
`cache/`.

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Backup/` — new: `LibraryIdentity`,
  `BackupLayout`, `BackupManifest`, `MediaBackupper`, `BackupRunner`.
- `AtelierIngestion/Sources/AtelierIngestion/Media/MediaStore.swift` —
  `storeBlobFile(copyingFrom:hash:fileExtension:)`; `atomicWrite` refactored
  onto a shared `atomicInstall`.
- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` — public
  `schemaVersion`, so manifests can record the migration they were written from.
- Tests (new, 58): `LibraryIdentityTests`, `BackupLayoutTests`,
  `BackupManifestTests`, `MediaBackupperTests`, `BackupRunnerTests`.

## Test results

`AtelierIngestion` — **259 tests passed**. `AtelierCore` — **567 tests passed**.
`AtelierRefs` scheme — **BUILD SUCCEEDED** (nothing in the app calls the engine
yet).

## Migration notes

No schema change and no behaviour change: nothing in the app calls any of this
yet. The first backup run of an existing library mints `library-id` at the
Library root — one 16-byte file, created on demand, never rewritten.

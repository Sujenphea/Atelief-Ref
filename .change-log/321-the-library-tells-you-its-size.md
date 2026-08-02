# 321 — The Library Tells You Its Size (016 · A · L1)

Settings ▸ Library held a path and a "Show in Finder". It now holds the
library's **size, broken out per tier**, what's in it by kind and platform, the
**largest files on disk**, and buttons for the cleanup machinery that has been
sitting headless since 010. Importers (016 B) are still L3.

## Summary

- **`LibraryStorageScanner` + `LibraryStorageUsage`** (new, AtelierIngestion) —
  a read-only `stat` walk over an injected `LibraryLayout`. Database, `blobs/`,
  `thumbnails/`, `cache/` and `snapshots/` are measured **apart**, which is the
  point: apart is what produces the "regenerable: X" figure, and until now
  nothing said what 008 H2's Time-Machine exclusion was actually worth.
- **`LibraryStats`** (new, AtelierIngestion) — the pure join between Core's blob
  rows and the disk's blob sizes. Sizes are measured once per scan and read from
  the cache afterwards; nothing `stat`s a file per render.
- **`AppServices.assetCountsByKind` / `assetCountsByPlatform` / `blobUsage`**
  (new, Core) — three reads, aggregated in SQL. `blobUsage` is the largest-items
  list's DB half.
- **`ThumbnailBackfill`** (new, AtelierIngestion) — the one thing here that
  didn't already exist; see below.
- **`LibraryStatsController`** (new) — shaped after `BackupController` (301) for
  the third time on purpose: same `@Published progress`, same `CancelFlag`, same
  "work off the main actor, state `@MainActor`", same monotonic `seq`. Owned by
  `IngestionModel`, not `SettingsView`, because that window can be closed and
  reopened mid-scan.
- **`LibraryStatsCopy`** (new) — the words, in a testable AppKit-free enum,
  keeping H4's split: facts and phrasing here, layout in the view.
- **Settings ▸ Library** — Measure Library / Stop with progress, the size and
  count rows, a Largest Items disclosure, and the five cleanup buttons. It sits
  directly above Backup, so the library-as-storage is one subject in one place.

## No new engine, and where that line was drawn

Every cleanup button is a call into something already written and already
tested: `MediaReaper.reapOrphanedBlobs`, `AppServices.integrityCheck`,
`AppServices.reconcileOrphanedKnownItems`, and — for Snapshot Now — the *same*
`snapshotNow()` File ▸ Snapshot Now calls, reused rather than duplicated, so
there is one manual-snapshot path in the app.

The keep-set the sweep passes is `referencedBlobHashes()`, not
`referencedBlobs()`: the reaper's parameter is `Set<String>` because it derives
each **orphan's** extension from the file it found on disk and never needs a
**live** blob's mime type. The thumbnail job takes `referencedBlobs()` instead,
and needs both halves of it — the mime names the file to open, and tells the
backfill whether to render a video poster frame or decode an image.

`ThumbnailBackfill` is the one piece that had to be written: nothing headless
existed to rebuild a purged tier. It is a composition of `ThumbnailGenerator` +
`MediaStore.storeThumbnail` following `IngestPipeline`'s tier logic to the
letter (only the missing tiers; one poster frame rendered once at the largest
tier and fed back through the image path). It writes only into `thumbnails/` and
deletes nothing.

## A library that moves under the scan

The user can empty the Trash — or restore from it — while a scan of a hundred
thousand files is running. That isn't an error condition, so the scan is two
phases: collect the file list, then size it. A file that vanished in between is
**skipped**, and excluding it is the *correct* total, not a degraded one. A file
that appeared after phase 1 simply lands in the next scan.

Sizes are read through a **fresh** `URL` value, deliberately: URLs handed out by
a directory enumerator carry cached resource values, and a cached size would
report bytes for a file that has since been trashed — the exact number this
whole feature exists to stop being wrong about.

Cancellation **throws** rather than returning what it measured so far. A
half-measured library is a wrong number, and a wrong number displayed
confidently is the failure mode being fixed.

## Cancelling still must not look like failing

301's lesson, applied: `run` checks the cancel flag **before** it classifies any
thrown error, because Stop tears down the surrounding task and whatever was in
flight — a GRDB read, the size loop — throws on the way out. A user who pressed
Stop is told the job stopped.

Only `scan` and `thumbnails` claim a progress bar. `integrity` and `reconcile`
can't (a `PRAGMA` is opaque), and the orphan sweep's denominator lives inside
`MediaReaper` — inventing a hook there to feed a bar would mean changing tested
machinery for cosmetics. Those three show a spinner instead of a bar that
pretends.

## Figures that know when they're out of date

A delete from the largest-items list, or a sweep that reclaimed something,
marks the measurement **stale**, and the line under the sizes says so and points
at Measure again. Deleting doesn't reclaim bytes immediately — reaping is
deferred so an in-session ⌘Z finds them (010) — so subtracting the row's size
would have been the confident lie in a different costume.

A largest-items row is one **file**, not one asset: dedup means a 240 MB video
can back three assets, and ranking assets would have shown it three times and
implied 720 MB that isn't there. Delete therefore removes every asset sharing
the blob (the row says "shared by 3 items" when it does), through the same
stage-then-confirm pair the grid, inspector and canvas use — pre-destructive
snapshot, recoverable backup, ⌘Z registration, all unchanged.

The row's other natural action — open the in-app detail page — is deliberately
absent. The detail overlay is routed by `NavModel.presentedItemID` over the main
window's *loaded collection*; Settings is a separate scene with no `NavModel` in
reach, and wiring it would mean building cross-window navigation. Reveal in
Finder and Open (in Preview/QuickTime) are the existing ways to look at a file
from anywhere, and they are what the row offers.

## Files changed

- `AtelierCore/Sources/AtelierCore/Services/BlobUsage.swift` — new.
- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` — the three
  library-stats reads, beside `referencedBlobs`.
- `AtelierIngestion/Sources/AtelierIngestion/Media/LibraryStorageScan.swift` —
  new (tiers, usage, the two-phase scanner).
- `AtelierIngestion/Sources/AtelierIngestion/Media/LibraryStats.swift` — new
  (the pure join + ordered counts).
- `AtelierIngestion/Sources/AtelierIngestion/Media/ThumbnailBackfill.swift` — new.
- `AtelierRefs/AtelierRefs/LibraryStatsController.swift` — new.
- `AtelierRefs/AtelierRefs/LibraryStatsCopy.swift` — new.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — owns the controller;
  `runLibraryJob`, `canRunLibraryJob`, the largest-items reveal / open / delete,
  and one shared `blobURL(forBlobHash:mimeType:)` the asset-based callers now
  route through.
- `AtelierRefs/AtelierRefs/SettingsView.swift`,
  `AtelierRefsApp.swift` — the Library section; `libraryStats` observed
  separately from `model`, since a nested `ObservableObject` doesn't propagate
  through its owner and progress ticks would never arrive.
- Tests (new, 61): `AtelierCoreTests/ServicesLibraryStatsTests.swift` (10),
  `AtelierIngestionTests/LibraryStorageScanTests.swift` (18),
  `AtelierIngestionTests/ThumbnailBackfillTests.swift` (8),
  `AtelierRefsTests/LibraryStatsControllerTests.swift` (15),
  `AtelierRefsTests/LibraryStatsCopyTests.swift` (10 + 5).

## Test results

- `swift test --package-path AtelierCore` — **594 tests in 87 suites passed**.
- `swift test --package-path AtelierIngestion` — **285 tests in 33 suites passed**.
- `AtelierRefs` scheme (`build-for-testing` + `test-without-building`,
  `-destination 'platform=macOS'`) — **TEST EXECUTE SUCCEEDED**, 1098 passing
  test cases, 0 failures.

## Migration notes

**None.** Reads plus a filesystem scan: no schema change, no on-disk change, and
no new `UserDefaults` key — the measurement is in-memory and recomputed on
request, never persisted, so 016 · C's `library.<id>.` namespacing rule has
nothing to apply to yet. Every path is derived from the injected `LibraryLayout`
(`store.layout`); nothing added here reaches the container directly.

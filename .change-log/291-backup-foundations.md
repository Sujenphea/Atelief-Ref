# 291 — Backup foundations (008 · F1–F3)

The three shared seams the off-device backup (H4/H5) and the portability
archive (H6/H7) both need, built ahead of either so neither has to work around
their absence. Plan: `.docs/068-backup-portability-plan.md`. No feature is
user-visible yet.

## Summary

- **F1 — `BlobRef` + `AppServices.referencedBlobs()`.** File-level work needs
  each blob's mime (to derive its stored extension), but
  `referencedBlobHashes()` returns hashes only. Rather than add a second struct
  identical to `OrphanedBlob`, that type is **renamed `BlobRef`**: "a blob hash
  plus the mime that names its file" is one concept, and the guarantee
  (reclaimable vs live) belongs to the API that returns it — `deleteAssets`
  still emits them, and `reap(_ orphans:)` keeps its parameter name.
  `referencedBlobs()` emits one row per distinct hash and settles two nuances in
  SQL instead of leaving them to chance: a NULL mime becomes `""` (matching the
  dotless path `MediaStore` writes for an unresolvable mime), and conflicting
  mimes for one hash resolve via `MIN` so a backup diff is reproducible.
- **F2 — `FolderAccess`** (new, app target). Two protocols, each with an
  immediate test consumer: `FolderAccess` (what a backup engine depends on —
  `DirectFolderAccess` lets its tests use a plain temp dir) and `BookmarkVault`
  (what `StoredFolderAccess` depends on, so persistence, staleness, and error
  handling are tested without the sandbox, which cannot mint a powerbox-granted
  URL in-process). Adds `com.apple.security.files.bookmarks.app-scope` to the
  entitlements plus a matching assertion in `scripts/verify-release.sh` check 5,
  since an unsigned CI build can't catch its absence.
  Two behaviours deliberately pinned: a failed bookmark persists **nothing**
  (never a half-chosen target), and an unresolvable bookmark is **kept** — an
  unplugged drive should mean "plug it back in", not "set up your backup again".
- **F3 — `BoundedWork.swift`.** `runBounded` and `ProgressReporter` moved out of
  `IngestCoordinator`, generalized over `Element: Sendable`, and made public.
  The logic never depended on what it was processing, so a backup copier now
  shares it instead of the codebase carrying a third hand-rolled
  bounded-concurrency loop. `IngestCoordinator` consumes the generic version, so
  its existing suite guards the refactor.

## Files changed

- `AtelierCore/Sources/AtelierCore/Services/BlobRef.swift` — renamed from
  `OrphanedBlob.swift`; doc rewritten around both directions.
- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` — `referencedBlobs()`.
- `AtelierIngestion/Sources/AtelierIngestion/Pipeline/BoundedWork.swift` — new.
- `AtelierIngestion/Sources/AtelierIngestion/Pipeline/IngestCoordinator.swift` —
  consumes the extracted helpers.
- `AtelierRefs/AtelierRefs/FolderAccess.swift` — new.
- `AtelierRefs/AtelierRefs/AtelierRefs.entitlements`, `scripts/verify-release.sh`.
- Type rename touched `MediaReaper.swift`, `ServicesDeleteTests.swift`, and
  `MediaReaperTests.swift` (mechanical, compiler-checked). Call sites naming the
  *method* `reapOrphanedBlobs` — `IngestionModel`, `OrphanGCTests` — are
  unchanged: that name still describes what it does.
- Tests: `ServicesReferencedBlobsTests.swift`, `BoundedWorkTests.swift`,
  `FolderAccessTests.swift` (all new).

## Test results

AtelierCore 567, AtelierIngestion 201, AtelierRefs app suite — all green.

## Migration notes

No schema change and no on-disk change. `OrphanedBlob` no longer exists as a
name; every reference was updated in-tree (the type is local to these packages,
so there are no external consumers). The new entitlement takes effect at the
next signed build — `verify-release.sh` now fails the release if it is missing.

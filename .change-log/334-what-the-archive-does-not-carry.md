# 334 — What the archive doesn't carry, and the window where writes vanish

## Summary

An audit of the backup / export / import surface. The machinery came out sound —
94 backup-and-restore tests, the full 359-test ingestion suite, 67 export tests and
the app target all passed untouched — so nothing here is a bug fix. Six changes,
all of them about the gap between what these features *do* and what they *say*.

### The archive claimed more than it carries

`space`, `space_item` and `saved_search` are not in the manifest. That is a settled
decision (068, 2026-08-03) and it stays settled. What did not hold up is the
sentence beside the button, which read "a manifest.json describing **the whole
library**".

The exclusion is not symmetric with the others. `asset_analysis` and
`asset_embedding` are recomputable; a tag attached to no asset can't be recreated
by any writer but also can't be missed. Space **text elements** are neither: they
live nowhere but `space_item.style`, nothing derives them, and no other export
carries them. Archive → wipe → re-import silently drops every board. The explainer
now names Spaces and saved searches and points at Backup — which copies the whole
database and is unaffected — as the complete copy.

Pinned by `ArchiveCopyScopeTests`, including a test that the words "whole library"
do not come back.

### Nothing was frozen once a restore was staged

`applyPendingRestore` replaces the live database at the next launch, so everything
written between staging and relaunch is discarded. `canRunBackup` and
`canRestoreBackup` both guarded on `hasPendingRestore`; `canImportArchive` did not.
An import in that window filled a progress bar, reported "imported 900 items", and
then evaporated on the relaunch the user had just been told to perform.

Two changes. `canImportArchive` now takes the guard — it is the archive verb that
*writes*, which is exactly what makes it different from `canArchiveLibrary`, which
only reads and deliberately stays available. And the main window carries a standing
banner for as long as a restore is pending.

The banner is the more general fix. The one-shot alert says what *will* happen; it
cannot say what it costs to keep working, because it is gone by the time anyone
does. Captures still land, items still drag, notes still get typed — the banner is
what makes that window visible. It has no dismiss: the condition doesn't stop being
true by being acknowledged.

### Off-device backup was a secret

`BackupCadence.default` is `.manual` and no folder is chosen out of the box, so the
machine-loss case — the entire reason H4/H5 exist — was unprotected until someone
went looking in Settings. Onboarding mentioned snapshots, which live *inside* the
library and die with it, and never mentioned backup at all.

The default is unchanged and should be: copying gigabytes to someone's drive must
not begin unasked. What was missing was the sentence telling them the option
exists. It is a non-numbered card, like the outro, so the header's "three quick
steps" still matches the three numbered rows and the first capture isn't held
behind a decision about which drive to use.

## The three smaller ones

**A manifest over an empty tree.** `LibraryArchiveWriter` wrote `manifest.json`
even when every copy had failed, producing a folder that reads as a finished
archive — the manifest is the commit record — holding no media at all.

The first attempt guarded on `files == 0 && skipped > 0` and broke two existing
tests, correctly. `skipped` folds together two causes that mean opposite things: a
source blob already reaped (a fact about the library, which the archive is supposed
to record and move past) and a copy the destination refused (a fact about the
destination being full or read-only). A one-asset library whose blob was gone would
have been failed outright.

So `Result` now carries `writeFailures` as a named subset of `skipped`, and the
guard is "the destination refused every copy" — `writeFailures > 0 && files == 0`.
A *partial* write failure still commits: `.incomplete` names the count, and half an
archive the user can see beats none.

**A sample that couldn't rotate.** `BackupVerifier.sample` took its offset as `seed
% stride`. With a tree only a little larger than the limit, `stride` collapses to 1
and every seed yields offset 0 — the same 32 files re-checked forever, on exactly
the destinations small enough for rotating to be cheap. The offset is now taken
modulo the *count*. Picks stay distinct because `stride * limit <= count` means the
walk spans less than one lap, and the existing spread and determinism tests are
unchanged.

**Archiving the library into itself.** Backup has `BackupTarget.rejection` for this;
archive had nothing. Harmless today — the writer reads from the database, not the
destination tree — but the next archive would copy the previous one in wholesale.
The model now applies the same `isSelfOrDescendant` check and surfaces it through a
new `ArchiveExportController.reject(_:)`, which lands on the same row a failed run
does. Ignored mid-run, so it can't overwrite the outcome of real work.

## Files changed

- `AtelierRefs/AtelierRefs/ArchiveExportController.swift` — the explainer's
  exclusions; `insideLibrary` / `nothingCopied` copy; `reject(_:)`; the
  `ArchiveWriteError` branch in the failure classifier.
- `AtelierRefs/AtelierRefs/LibraryArchiveWriter.swift` — `ArchiveWriteError`,
  `Result.writeFailures`, the refuse-the-manifest guard.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `canImportArchive` takes
  `!hasPendingRestore`; `archiveLibrary()` rejects a destination inside the library.
- `AtelierRefs/AtelierRefs/AppShellView.swift` — the pending-restore banner.
- `AtelierRefs/AtelierRefs/BackupTarget.swift` — `restorePending`.
- `AtelierRefs/AtelierRefs/OnboardingSheet.swift` — the backup card.
- `AtelierIngestion/Sources/AtelierIngestion/Backup/BackupVerifier.swift` — the
  sample offset.
- Tests: `LibraryArchiveExportTests` (destination-refuses-everything,
  missing-blob-still-commits, the two `reject` cases, `ArchiveCopyScopeTests`),
  `RestoreCopyTests` (the banner's words, and `restorePending` added to the
  don't-collide set), `BackupVerifierTests` (stride-collapse rotation).

## Migration notes

None — no schema change, no manifest change, no stored-format change. Archives
written before this read back identically; `manifest_version` and `schema_version`
are untouched.

Two behavioural changes worth knowing:

- **Import Archive… is disabled while a restore is pending.** Previously allowed,
  and previously discarded on relaunch.
- **An export whose destination refuses every copy now fails instead of writing a
  manifest.** A folder from such a run is no longer offered as importable — which
  is the point, since it held nothing. Existing folders are unaffected.

## Not done

The archive still does not carry Spaces or saved searches. Carrying them is a real
option — `ArchiveLayout` was built with a `Spaces/` sibling in mind and the header
says so — but it needs manifest entries, replay writers and round-trip tests, and
it reverses a settled decision. This change makes the current scope honest; it does
not widen it.

# 327 — A Backup That Runs Itself, and Proves Itself (008 · H5d)

301 taught the app to back up on demand and 326 taught it to come back. This
closes H5 with the two things a backup needs to be worth having: it happens
**without being asked**, and it can be **checked** rather than believed. No
schema change — the library is still at v18.

## Summary

- **`BackupCadence` + `BackupCadenceStore`** (new, AtelierRefs) — Manually /
  Daily / Weekly, persisted per library under `library.<id>.backupCadence`.
  Daily by default; see "Why daily rather than manual" below.
- **`BackupController.backUpIfStale(…)` + `BackupController.isStale(…)`** — the
  `SnapshotManager.snapshotIfStale` shape, with the clock injected the same way.
  Called from `bootstrap()` in a background `Task`, after everything else, and
  below the daily snapshot.
- **`BackupVerifier` + `BackupVerifyResult`** (new, AtelierIngestion) — the
  sampled re-hash H5a deferred. Deterministic, capped, seed-rotated, and it
  deletes nothing. `.full` is the same code path with the cap removed.
- **`BackupVerifyController` + `BackupVerifySummary`** (new, AtelierRefs) — the
  `ExportController` shape for the fifth time; cancel flag read **before** any
  error is classified.
- **Settings ▸ Backup** gains an "Automatically" picker and a check row
  ("Check Backup" / "Check All Files"), with verification prose on
  `BackupTarget` — AppKit-free and fully tested, per H4's split.
- 43 new tests (16 `AtelierIngestionTests`, 27 `AtelierRefsTests`).

## The cadence

macOS gives a sandboxed app that isn't running no way to copy anything, so
"automatic" can only mean *checked at launch* — the same conclusion H3 reached
for snapshots, and the same implementation: compare the last good run against a
maximum age over an injected clock, and if it is older, do one in a background
task. Nothing is scheduled and no timer exists.

Four refusals, each with its own test:

- **Manual** — the user said "when I say so". `maxAge` is `nil`, so the path
  returns before it resolves anything.
- **A pending restore** — the guard "Back Up Now" already carries (H5c), and it
  matters *more* here: if the staged restore came from this target, an
  unattended run would overwrite the very backup the user is one relaunch away
  from restoring, and nobody pressed a button to cause it.
- **A bookmark that doesn't resolve** — skipped silently, not recorded as a
  failure. An unplugged external drive is the normal state of a backup disk;
  "Last backup failed" at every launch would train the user to ignore the one
  time it means something.
- **A run already in flight.**

**Only a run that LANDED resets the clock.** A failed or cancelled run leaves
the destination exactly as stale as it was, so counting either as a backup would
buy a whole cadence period of silence for a backup that never happened. An
*incomplete* run does reset it: it finished and installed a verified database,
and what it couldn't copy was a blob missing at the **source**, which re-running
cannot conjure back — treating that as stale would attempt a full backup on
every launch forever over a fault the status line already reports in words.

### Why daily rather than manual

Choosing a backup folder is already the statement of intent. Making the copying
itself a second, separate opt-in produces the most common backup failure there
is: one that was set up once, ran once, and has been months stale ever since
without anyone noticing. It is the same reasoning that made H3's daily snapshot
on-by-default, and it costs nothing until a folder is chosen. An unrecognised
stored value (a preference written by a future build) also degrades to daily
rather than to manual — falling back to "off" would silently stop the backups of
anyone who ran a newer build once.

## The verification

The filename **is** the hash, so the check is self-describing: re-read
`blobs/ab/cd/<hash>.<ext>`, hash the bytes back, compare to the name. Nothing
extra had to be recorded at backup time, which is exactly why this was worth
deferring out of H5a rather than approximating with sizes or timestamps.

**Sampled by default, because reading is the cost.** Enumerating a destination
stays metadata-cheap even when its files are dataless — an iCloud Drive folder
evicted locally is the case that matters — but *reading* one forces a download.
So the routine check re-hashes a capped sample (32), the exhaustive one is its
own button, and both report the bytes they read so the price is on screen. The
destination's `library.sqlite` is integrity-checked on every pass regardless: it
is one bounded read-only `PRAGMA integrity_check`, and it is the artifact a
restore cannot proceed without.

**The sample is deterministic.** Sorted by hash, then taken at a fixed stride
from a seed-chosen offset. Striding rather than taking the front is what makes
the check mean anything — the first 32 files would re-verify one shard directory
forever and imply the whole backup — and the seed rotates *which* stride offset
without ever making a single check unreproducible. A random pick would be
untestable here and unanswerable in a support conversation.

**A finding never prunes.** `BackupVerifier` has no delete, move, or rewrite in
it, and that is a refusal rather than an omission: a file whose bytes disagree
with its name is still the only copy of something at a destination the user
restores *from*, and a transient read error on a network volume looks exactly
like corruption. Every user-facing sentence about a finding says outright that
nothing was deleted, because that is the first question it provokes. Pinned by
tests in both the engine and the controller.

Unreadable is reported apart from mismatched. The bytes were never seen, so
calling them wrong would be a guess dressed as a measurement — and the remedies
differ ("bring the drive online" versus "this backup can't be trusted").

## Files changed

**New**

- `AtelierIngestion/Sources/AtelierIngestion/Backup/BackupVerifier.swift`
- `AtelierIngestion/Tests/AtelierIngestionTests/BackupVerifierTests.swift`
- `AtelierRefs/AtelierRefs/BackupCadence.swift`
- `AtelierRefs/AtelierRefs/BackupVerifyController.swift`
- `AtelierRefs/AtelierRefsTests/BackupCadenceTests.swift`
- `AtelierRefs/AtelierRefsTests/BackupVerifyControllerTests.swift`

**Modified**

- `AtelierRefs/AtelierRefs/BackupController.swift` — injected clock, cadence
  preference (`activate(libraryID:)` / `setCadence`), `backUpIfStale`, `isStale`.
  The run's `finishedAt` now comes from that clock rather than `Date()`.
- `AtelierRefs/AtelierRefs/BackupTarget.swift` — verification and cadence prose.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `verify` controller, cadence
  activation in `bootstrap()`, the launch-time `backUpIfStale()` task,
  `canVerifyBackup` / `verifyBackupNow`, and `verify.isRunning` folded into the
  existing mutual-exclusion guards.
- `AtelierRefs/AtelierRefs/SettingsView.swift` — the cadence picker and the check
  row, both inside the Backup section.
- `AtelierRefs/AtelierRefs/AtelierRefsApp.swift` — passes `verify:` to
  `SettingsView`.

## Migration notes

**None.** No schema change (v18 stands), no migration registered, and no change
to the on-disk backup layout — a destination written by H5a/H5b/H5c verifies as
it is, and one written by this build restores into an older one unchanged.

One new `UserDefaults` key, namespaced per library:
`library.<id>.backupCadence`. Absent ⇒ daily, so an existing install begins
backing up automatically at its next launch **only if** it already has a backup
folder chosen and its last successful run is over a day old. Anyone who wants
the previous behaviour sets Settings ▸ Backup ▸ Automatically to "Manually".

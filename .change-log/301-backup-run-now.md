# 301 — Back Up Now (008 · H5b)

The two slots `299-backup-folder-target` deliberately left empty in Settings ▸ Backup are
filled: a **Back Up Now** button with progress and a Stop, and a **last-run
status line** that survives quitting the app. Restore is still H5c.

## Summary

- **`BackupController`** (new) — shaped after `ExportController` (052 · B3) on
  purpose: same `@Published` progress, same `CancelFlag`, same "work runs off
  the main actor, state is `@MainActor`" split. Two long-running user-facing
  jobs behaving alike is worth more than either being individually clever. Owned
  by `IngestionModel`, not `SettingsView`, because that window can be closed and
  reopened mid-run.
- **`BackupRunSummary` + `BackupSummaryStore`** (new) — the last run, persisted
  in `UserDefaults`. Four outcomes: `succeeded`, `incomplete`, `cancelled`,
  `failed`.
- **`BackupTarget`** gains the words for run failures and the status line,
  keeping H4's split (facts and rules in a testable, AppKit-free enum; layout in
  the view).
- **`FolderAccess`** grows an async `withAccess` — see below.
- **Settings ▸ Backup** — Back Up Now / Stop / progress bar, the status line,
  and the failure remedy when there is one. Choosing and clearing the folder are
  disabled while a run is in flight.

## The async security scope

A security scope is held per-URL for the duration of a call, and the existing
`withAccess` was synchronous. A backup copying thousands of files suspends
constantly — the scope would have been torn down at the first `await` and every
copy after it would have failed on permissions, for a reason the user could do
nothing about.

`FolderAccess` now declares three primitives (`resolve`, `beginAccess`,
`endAccess`) and a protocol extension supplies **both** brackets, so the `defer`
that releases the scope is written once rather than once per conformance and per
overload. Holding a scope across `await` is legitimate — it's a property of the
URL, not of the calling thread; what matters is releasing it exactly once, which
the shared `defer` guarantees.

## Cancelling must not look like failing

`cancel()` sets the flag **and** cancels the wrapping task — the flag is what
the copy loop reads per file, and the task cancellation is what stops
`runBounded` from launching the remaining thousands of no-op items, so a stop
during a large run is immediate rather than merely eventual.

The consequence, which the tests caught: work already in flight (a GRDB read,
the copy loop) throws on the way out, and those throws were being classified as
`failed`. So `perform` now checks the cancel flag **before** it classifies any
error. A user who pressed Stop must not be told their backup failed.

## Outcomes, and why there are four

`incomplete` earns its place. A run where some blobs had no file on disk
finishes with a usable destination — database, manifest, everything else copied.
Calling that `succeeded` would hide a real problem; calling it `failed` would
imply the previous backup was lost. It gets its own outcome and its own
sentence, with the **count** in it: "some files" leaves the user unable to tell a
rounding error from half their library.

A record this build can't decode (a summary written by a future version, with a
`BackupOutcome` case that doesn't exist yet) reads back as **no record** rather
than crashing or resurrecting a stale one. A missing status line is a small lie;
a confidently wrong one is a big one.

Clearing the backup folder also forgets the last run — "Last backed up 2 days
ago" next to a folder the app no longer has is true and useless, and reads as
though the backup is still current.

## Files changed

- `AtelierRefs/AtelierRefs/BackupController.swift` — new.
- `AtelierRefs/AtelierRefs/BackupRunSummary.swift` — new.
- `AtelierRefs/AtelierRefs/BackupTarget.swift` — run-failure messages, the
  status line, and a relative-time helper that clamps a future timestamp
  (a clock adjustment shouldn't produce "in 3 hours").
- `AtelierRefs/AtelierRefs/FolderAccess.swift` — three primitives + a protocol
  extension supplying the sync and async brackets.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — owns the controller;
  `runBackupNow()`, `canRunBackup`; clearing the folder forgets the last run.
- `AtelierRefs/AtelierRefs/SettingsView.swift`,
  `AtelierRefsApp.swift` — the run row; `backup` observed separately from
  `model`, since a nested `ObservableObject` doesn't propagate through its
  owner and progress ticks would never arrive.
- Tests (new, 33): `AtelierRefsTests/BackupControllerTests.swift` (a real temp
  library + `DirectFolderAccess`, so nothing needs the sandbox),
  `AtelierRefsTests/BackupStatusTests.swift`.

## Test results

`AtelierRefs` scheme — **TEST SUCCEEDED**, 965 test cases.

## Migration notes

No schema or on-disk change. The last-run record lives under
`AtelierBackupLastRun` in `UserDefaults`; absent until the first run, and
removed when the target is cleared. The first run of an existing library mints
`library-id` at the Library root (`300-backup-copy-engine`).

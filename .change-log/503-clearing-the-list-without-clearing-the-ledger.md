# 503 — clearing the list without clearing the ledger

## Summary

The Sweeps tab accumulates a row per bulk import forever. Finished sweeps have no
exit: `Retry Failed` disappears once there is nothing retryable, and there has
never been a way to put a completed import away. Adds a **Clear Log** toolbar
button beside `Turn Off Bulk Import`.

The interesting part is what it must NOT do. `job_item` cascades from `job`, and
those item rows are exactly the set `knownSourceIDs(forJob:)` answers with — the
platform-scoped ids a sweep consults to skip RE-DOWNLOADING what it already has
(P14), read across every job of that platform, cleared or not. A `DELETE FROM job`
behind a tidy-up button would therefore have made the next sweep re-fetch the
user's entire import history. Content-addressing would still dedup the bytes on
arrival, so nothing would duplicate — the cost would be paid silently, in
bandwidth and in rate-limit budget, against the one promise the consent panel
makes about re-sweeps: *"Re-sweeps skip what you already have."*

So a clear HIDES. `job.cleared_at` is stamped; the row and its items stay.

Terminal-only, for a second reason: an `open` or `paused` sweep is live work with
`Pause` / `Resume` / `Cancel` attached to it, and a paused sweep that cannot be
seen cannot be resumed. The button is disabled rather than hidden while every
sweep is still running, so it does not move around under the user.

## Files changed

- `AtelierCore/Sources/AtelierCore/Domain/Job.swift` — `clearedAt: Date?`
  (`cleared_at`), defaulted in the memberwise init so no existing caller changes.
- `AtelierCore/Sources/AtelierCore/Persistence/Migrator.swift` — migration `v24`,
  `ALTER TABLE job ADD COLUMN cleared_at TEXT`. Additive, no backfill.
- `AtelierCore/Sources/AtelierCore/Services/AppServices+Jobs.swift` — `listJobs`
  filters `cleared_at IS NULL`; new `clearFinishedJobs(now:)` stamps every
  uncleared `complete`/`halted` job in one write transaction and returns the count.
  `knownSourceIDs` is deliberately untouched — it must keep seeing cleared jobs.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `hasFinishedSweeps` (the
  button's enabled state) and `clearSweepLog()`.
- `AtelierRefs/AtelierRefs/BulkSweepsView.swift` — the toolbar button and its
  confirmation dialog.
- `AtelierCore/Tests/AtelierCoreTests/ServicesJobTests.swift` — four tests, the
  load-bearing one being that a cleared sweep's sources are still returned by
  `knownSourceIDs` for a NEW job.
- `AtelierCore/Tests/AtelierCoreTests/MigrationTests.swift` — `v24` appended to the
  pinned committed list; a suite pinning "existing rows upgrade to NULL" and
  "`job_item` survives".

## Migration notes

`v24` runs on first launch after upgrade. Every existing sweep has
`cleared_at NULL`, so the list shows exactly what it showed before.

One-way by design: nothing un-clears a sweep. That is safe because the only route
back into a job is `resumeJobId`, which `JobRoutes.openOrReopen` accepts solely for
an `open` or `paused` job — and only terminal jobs can be cleared, so a cleared
sweep was already unreachable from the extension before this change.

## The gap this leaves

Cleared rows are never reaped, so `job` grows without bound (one row per sweep,
plus its items). That is the same trade the download-skip set already makes — the
items have to live as long as the imported assets do — but the JOB rows themselves
are now pure dead weight once cleared. If that ever matters, the reap is safe only
for a job whose items are all `skipped`/failed, i.e. one that contributed nothing
to the skip set.

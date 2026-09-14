# 507 — a sweep that only breathed when it spoke

## Summary

A live re-sweep of an already-imported 116-note rednote board stopped after two
items and reported nothing wrong:

```
sweep SETTLED halted {"ingested":2,"deduped":0,"skipped":82,"retryableFailed":0,"permanentFailed":0}
```

`ingested: 2` is rednote's `MAX_CONCURRENCY` — the two workers in flight when the
sweep was told to stop. Nothing failed. The app had paused the job underneath it.

A job's `updated_at` had exactly one writer: `recordJobItem`, which fires only when
an item is RELAYED. `pauseStaleOpenJobs` flips any `open` job idle for
`staleSweepSeconds` (90) to `paused`, and it runs every time the Sweeps tab polls.
So "idle" meant "has not relayed", and a live sweep is not relaying for minutes at
a time:

- a dedup skip takes no relay and no pacing at all — it is decided in the browser
  against the known-set, which is the entire point of P14;
- rednote's note-open pass spends `NOTE_OPEN_PACING_MS` + jitter per note plus up
  to `NOTE_OPEN_TIMEOUT_MS` waiting for each one, relaying nothing whenever the
  notes it opens hold only already-known images;
- a scroll, a feed reset (8s timeout, 1.2s settle) or a stretch of empty notes
  produces no items at all — so even a per-item hook would not have covered it.

The sweep then read `jobStatus: "paused"` off its next relay, `classifyIngestResult`
turned that into `signal: "halt"`, and it halted itself — correctly, on a pause it
had caused by being quiet.

So the sweep now says it is alive on a TIMER: `POST /jobs/{id}/progress` every
`SWEEP_HEARTBEAT_MS` (30s, a third of the app's window, so two pings can be lost
before a live sweep looks dead).

**The second half is the number the ping carries.** The Sweeps tab's "Skipped" stat
read `job_item`'s `skipped` tally, and that tally is structurally always 0 — a
`job_item` row exists only for something that came through `/ingest`, and a dedup
skip never goes near it. Nothing in the app writes `JobItemStatus.skipped` either
(`CaptureRoutes` maps ingest outcomes to `ingested` / `deduped` / `permanentFailed`
and nothing else), so the tab told that run it had skipped none of its 82. The ping
carries the engine's live `counts.skipped` into `job.skipped_count`, and the stat
reads that.

`skipped_count` is raised with `MAX`, never assigned. A resumed sweep reopens the
SAME job id while the engine's counts restart at 0 for that run and re-skip the
same known items on the way back to where they stopped; assigning would walk the
number backwards on every resume. `MAX` is monotonic across any number of resumes,
and it makes a retried or out-of-order ping harmless.

A ping is progress, not a transition. Nothing on this path writes `status`: a sweep
that has not yet noticed it was paused must not undo the pause by breathing. Such a
ping still raises the count — the skips it reports genuinely happened — but leaves
`updated_at` alone, so it cannot make a finished sweep look freshly active. The
reply carries the job's current status so the extension can SEE a pause it has not
relayed into yet; nothing acts on it, deliberately. The pause/cancel handshake stays
on the relay path (7A), and giving a heartbeat a second way to stop a sweep is its
own change.

## Files changed

- `AtelierCore/Sources/AtelierCore/Domain/Job.swift` — `skippedCount: Int`
  (`skipped_count`), defaulted in the memberwise init so no existing caller changes.
- `AtelierCore/Sources/AtelierCore/Persistence/Migrator.swift` — migration `v25`,
  `ALTER TABLE job ADD COLUMN skipped_count INTEGER NOT NULL DEFAULT 0`. Additive,
  no backfill.
- `AtelierCore/Sources/AtelierCore/Services/AppServices+Jobs.swift` —
  `recordJobProgress(jobID:skipped:now:)`: one write transaction that raises the
  count with `MAX` and stamps `updated_at` only while the job is `open`, returning
  the status it found.
- `AtelierServer/Sources/AtelierServer/JobDTO.swift` — `JobProgressRequest`,
  `JobResponse.jobStatus` + `.progress(jobStatus:)`, `JobDecoder.decodeProgress`
  (empty body → 0; a negative count → 400 rather than being absorbed by `MAX`), and
  the new `JobLedger` requirement.
- `AtelierServer/Sources/AtelierServer/JobRoutes.swift` — `handleProgress(jobID:body:)`.
- `AtelierServer/Sources/AtelierServer/CaptureServer.swift` — the
  `POST /jobs/{id}/progress` arm of the parametrized-path dispatch.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `SweepProgress.skipped` reads
  `job.skippedCount`; `staleSweepSeconds` now names the heartbeat it depends on.
- `extension/src/config.js` — `SWEEP_HEARTBEAT_MS`, with why it must stay well under
  the app's 90s.
- `extension/src/bulk-endpoint.js` — `reportJobProgress`.
- `extension/src/bulk-messages.js`, `extension/src/bulk-sw.js`, `extension/src/sw.js`
  — `BULK.progress` and its handler. Only the SW can reach 127.0.0.1, so the ping
  goes through the same transport every other job op does.
- `extension/src/bulk-controller.js` — the heartbeat: started once the job is open,
  stopped in a `finally` so a halt, a throw and a clean close all cancel it, and
  driven by an injected `setTimer`/`clearTimer` pair (defaulted to the real ones) for
  the same reason `sleep` and `random` are injected.
- Tests: `ServicesJobTests` (MAX-not-assign across a resume, a ping against each
  non-open status, notFound), `MigrationTests` (`v25` pinned; existing rows read 0;
  the column's default), `JobRoutesTests` + `JobServerIntegrationTests` (the route
  end to end, including that a ping cannot reopen a paused job),
  `bulk-endpoint.test.js`, `bulk-sw.test.js`, and `bulk-controller.test.js`'s
  start / count / cancel / failure-tolerance suite on fake timers.

## Migration notes

`v25` runs on first launch after upgrade. Every existing sweep reads
`skipped_count 0`, which is the number the tab already showed it, so nothing in the
list changes on upgrade.

**The two sides must be upgraded together to fix the pause.** The app's 90s window
and the extension's 30s heartbeat live either side of a process boundary and cannot
be one constant — each names the other. An old extension against a new app still
works, it just keeps the old behaviour (no pings, so a quiet sweep is still paused,
and `skipped_count` stays 0). A new extension against an old app gets a 404 on every
ping, which the controller logs and ignores.

## Two things worth knowing

**The heartbeat is unconditional.** It does not skip a ping when the count has not
moved and a relay landed recently. That test needs a clock injected beside the timer
and would save one loopback POST per 30 seconds, and the case it suppresses — counts
unchanged, a relay just landed — is exactly the case where `updated_at` is already
fresh and a lost ping costs nothing.

**A final ping fires before the close.** A sweep shorter than 30s never ticks, so
without it the ledger would keep 0 and the finished row would still read "0 skipped"
— half the bug, surviving the fix.

## The gap this leaves

`counts[.skipped]` is now unread by the Sweeps tab, and it should stay that way. The
engine tallies dedup skips and typed relay skips (020's exhausted video ladder) into
ONE `counts.skipped`, and that is the number the ping carries — so the day something
does start writing a `skipped` `job_item`, adding the two would count those twice.
There is a note to that effect on `SweepProgress.skipped`; it is a comment, not an
invariant anything enforces.

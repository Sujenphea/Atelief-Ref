# 067 — Reconcile abandoned sweeps (no more phantom "running" jobs)

Phase 9 live testing ([.docs/019](../.docs/019-bulk-import-verification.md) §T4)
surfaced an app-side bug: the sweep loop lives in the browser tab's content script,
so closing the tab mid-sweep kills it **before** it can send the `complete`/`halted`
message that closes the job. The ledger keeps the job `open`, and the Sweeps tab —
which equates `open` with "running" — shows it as a **phantom running sweep forever**;
the only way to clear it was to manually Pause it.

## Fix

**`AppServices.pauseStaleOpenJobs(olderThan:now:)`** (AtelierCore) — transitions every
`open` job whose `updatedAt` is older than `now - seconds` to `paused` (resumable),
returning the ids changed. Reads first and only opens a write when something is stale
(the poll calls it each tick). `now` is injected for deterministic tests; `seconds == 0`
pauses ALL open jobs.

Wired in `IngestionModel`:
- **On launch (`bootstrap`)** → `pauseStaleOpenJobs(olderThan: 0)`. Nothing can be
  running yet, so any leftover `open` job is abandoned → paused. Clears zombies across
  restarts unambiguously.
- **On each progress poll (`refreshSweeps`)** → `pauseStaleOpenJobs(olderThan: staleSweepSeconds)`
  with `staleSweepSeconds = 90` (safely past the engine's 30s max item backoff, so a
  live-but-throttled sweep isn't falsely reconciled). Handles the in-session case: a
  tab closed mid-sweep flips from "running" to "Paused" within ~90s.

An abandoned sweep now lands in the SAME `paused` state the user had to set by hand —
and the existing Resume / Cancel controls already act on it. A sweep that's still alive
when falsely reconciled halts cleanly on its next relay (7A `jobStatus` feedback) and
resumes from its checkpoint, so the reconcile is always safe.

## Tests (`ServicesJobTests.swift`, +3)

- `olderThan: 0` pauses every open job, leaves `complete`/`paused`/`halted` untouched.
- Age-gated: a 10s-idle open job is spared at threshold 90; a 200s-idle one is paused.
- No-op (no write, empty result) when nothing is open.

## Verified

`swift test` AtelierCore **190** (+3); `xcodebuild -scheme AtelierRefs` BUILD SUCCEEDED.

## Follow-up (not done here)

A resumed sweep still opens a NEW job, so one logical sweep can show as two rows
(the interrupted `paused` + the `complete` resume). Making resume *continue the same
job* (persist the jobId under the stable checkpoint key + a server "reopen" path) is
the cleaner one-row-per-sweep model — deferred.

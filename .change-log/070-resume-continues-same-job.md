# 070 — Resume continues the SAME job (one sweep, one ledger row)

Phase 9 T6 live testing showed a resumed sweep splitting into **two ledger rows** — the
interrupted `paused` job (e.g. 12 ingested) plus a brand-new `complete` job for the
remainder (64) — and, transiently, the old job stuck showing `open` ("loading") until
[067](./067-reconcile-abandoned-sweeps.md) reconciled it. Cause: every browser run
opened a **fresh** job, so a resume never continued the interrupted one.

## Fix — reopen the interrupted job instead of minting a new one

The checkpoint (stable per-board key, [066](./066-bulk-checkpoint-stable-key.md)) now
also carries the **jobId**; the controller hands it back on the next run so the app
reopens THAT job.

- **`bulk-controller.js`** — reads the prior checkpoint's `jobId` before opening and
  passes it as `resumeJobId`; wraps the engine's checkpoint store so every save stamps
  the current `jobId` in (the engine stays jobId-agnostic). The checkpoint-clear rules
  from [069](./069-pause-closes-resumable.md) already drop it on a terminal close, so a
  finished/cancelled sweep can't be revived.
- **`bulk-endpoint.js` / `bulk-sw.js`** — thread `resumeJobId` into the `POST /jobs` body.
- **`JobRoutes.handleCreateJob` (+ `CreateJobRequest` / `decodeCreate`)** — if
  `resumeJobId` names a **still-resumable** job (`open` or `paused`), reopen it
  (`setJobStatus → open`) and return its id; otherwise (absent, `complete`, `halted`,
  or unknown) mint a fresh job. A stale id is always safe — it falls through.

No app change: the Sweeps **Resume** button already flips the job to `open`, which the
browser reopen also accepts, so one logical sweep now stays one `complete` row.

## Tests

- **Server (AtelierServer, 73 pass):** reopen a resumable job (same id, no new job,
  status→open); a terminal job starts fresh; an absent id starts fresh. Fake ledger's
  `jobStatus` made realistic (throws `.notFound` for unknown jobs, matching `AppServices`).
- **Extension (node --test, 179 pass):** `openJob` includes `resumeJobId` only when set;
  the SW forwards it; the controller passes the checkpoint's `jobId` as `resumeJobId` on
  resume and stamps `jobId` into every checkpoint; a fresh sweep opens with none.

## Verified

AtelierServer `swift test` **73**; extension `node --test` **179**;
`xcodebuild -scheme AtelierRefs` BUILD SUCCEEDED. Requires an **extension reload** to
take effect. Live T6 Part B re-test (expect one `complete: N` row) pending.

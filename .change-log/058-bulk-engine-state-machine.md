# 058 — Bulk import: the sweep engine (Phase 3)

Phase 3 of bulk import ([.docs/018](../.docs/018-bulk-import-plan.md)): the pure,
platform-blind state machine that turns a per-platform `BulkSource` driver into a
paced, resumable, fault-tolerant sweep. No production wiring yet (that's Phase 6) —
this is the engine + its test harness. Decisions 2A / 7A / 10A / 13A / 14A, taxonomy
[C7], skip [P14], checkpoint [A1].

## Summary

- **`bulk-engine.js` — `runSweep(driver, input, opts)`.** A worker-pool state
  machine, everything injected (driver, `relay`, `knownSet`, `storage`, `sleep`,
  `random`), so it runs under `node --test` with no chrome.*, no network, no real
  timers. It:
  - **walks** the driver's async iterator, serializing `iterator.next()` across
    workers and stamping each item with a monotonic seq;
  - **dedup-skips** `[P14]` any `sourceId` in the known-set with NO relay and NO
    pacing, and grows the set as it ingests (a duplicate later in the same sweep is
    skipped too);
  - **paces** each relay (`PACING_MS` + jitter) and runs `MAX_CONCURRENCY` (2–3)
    items concurrently `[P13]`;
  - **retries** a `retryableFailed` item inline with exponential backoff
    (`computeBackoff`: base·2ⁿ, capped) up to `MAX_ITEM_RETRIES`, then records it
    `retryableFailed` and moves on — one bad item NEVER aborts the sweep `[C7]`;
  - **halts** on a `halt` signal (auth wall / app unreachable): records the item,
    stops pulling, drains in-flight, returns `status: "halted"` `[C7]`;
  - **checkpoints** `[A1]` the cursor of the last CONTIGUOUSLY-completed item to the
    injected store — the watermark never jumps past an item still in flight, so a
    resume can't skip a gap. Resume seeds enumeration from the saved cursor.
- **`classifyIngestResult(result)`** — the default mapper from an `ingestOne`
  result `[C5]` to `{ outcome, signal }` `[C7]`. Keys off `result.status` (robust)
  and refines with `result.httpStatus` when a caller supplies it (forward-compatible:
  absent today → safe status-based defaults; sharpens for free when a later phase
  surfaces the code). `unreachable` → halt (local app down → pause, resume later);
  `ingest-error` → permanent (our own app rejected it); `fetch-error` → retryable
  (transient CDN hiccup, bounded by the retry budget).
- **`config.js`** — bulk knobs added `[C8]`: `MAX_CONCURRENCY`, `PACING_MS`,
  `PACING_JITTER_MS`, `BACKOFF_BASE_MS`, `BACKOFF_MAX_MS`, `MAX_ITEM_RETRIES`. Every
  one is overridable per-run via `runSweep(..., { config })`; they govern pace /
  resilience / parallelism, never correctness (dedup + the ledger keep re-processing
  idempotent).

## Files changed

- `extension/src/bulk-engine.js` (new)
- `extension/src/config.js` (+ bulk-sweep knobs)
- `extension/test/bulk-engine.test.js` (new)

## Design notes

- **Why inline per-worker retry (not a global retry queue):** backoff timing is then
  just the sequence of `sleep` durations one worker emits — trivially assertable with
  a recording `sleep`, no simulated clock. A stuck item blocks one worker (others
  continue) and holds its watermark seq until terminal (correct for resume).
- **Halt vs retry-exhaustion are distinct** `[C7]`: exhausting an item's retry budget
  records `retryableFailed` and continues (a future sweep re-attempts it — it's not
  in the known-set); only a `halt` SIGNAL (auth wall / unreachable app) pauses the
  whole sweep. So one dead item can't halt a sweep, and a real throttle wall can.
- **Checkpoint precision isn't required for correctness** — the app's dedup + the
  known-set make any resume overlap idempotent (re-skip, never double-ingest). The
  contiguous watermark is the tighter guarantee (no *missed* item under concurrency),
  proven by the "later item finishing first" test.

## Deferred (next phases, unchanged from the plan)

The production `relay` — `ingestOne` composed with `classifyIngestResult`, carrying
the job's token/jobId — is Phase 6 wiring. The `BulkSource` drivers are Phase 4
(Pinterest) / Phase 5 (X). `classifyIngestResult` already consults `httpStatus`, so
when a driver/`ingestOne` surfaces it, classification sharpens with zero engine change.

## Verification

`npm test` green — 98 tests (79 pre-existing unchanged + 19 new): terminator,
dedup-skip (+ same-sweep duplicate), resume-from-cursor, contiguous checkpoint,
retry-requeue + backoff sequence, budget exhaustion, relay-throws, fatal halt (+
no-retry-on-halt, unreachable→halt), concurrent checkpoint ordering, progress
reporting, the `classifyIngestResult` table (+ httpStatus refinement), and the
relay guardrail.

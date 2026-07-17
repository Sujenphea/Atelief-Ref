# 158 — Bulk sweeps: failures list + retry (034 P2)

## Summary

A sweep's "Failed N" was a dead-end — a count with no way to see what failed or do
anything about it. The sweep row now:

1. **Explains the split** — an expandable "N temporary · M permanent" disclosure
   (temporary = 429/timeout/5xx, recoverable; permanent = 404/unsupported/decode).
2. **Lists the failed items** on demand — each with its source URL (a link that
   opens in the browser) and a temporary/permanent glyph. Loaded lazily when the
   row is expanded.
3. **Offers Retry** on a terminal sweep with temporary failures — re-opens the job
   so the next browser run re-attempts everything not yet ingested (only
   ingested/deduped items are in the download-skip set, so failures are retried).

No per-item error string is stored in the ledger, so "reason" is the
temporary/permanent classification the engine already records — no schema change.

## Files changed

### AtelierRefs
- `IngestionModel.swift` — `retrySweep(_:)` (re-open), `sweepFailures(jobID:)`
  (failed items, newest first); `SweepProgress.retryableFailed`/`permanentFailed`.
- `BulkSweepsView.swift` — `SweepRow` gains a lazy failures `DisclosureGroup` (split
  summary + per-item link rows) and a "Retry Failed" control for terminal sweeps
  with recoverable failures.

### AtelierRefsTests
- `SweepFailuresTests.swift` — `sweepFailures` returns only failed items; empty for
  a clean sweep.

## Migration notes

None. Reuses the existing `jobItems` read and the `setJobStatus` re-open path.

## Verify

- Run a sweep that produces failures → its row shows "Failed N"; expand the
  disclosure → the temporary/permanent split and the failed URLs (clickable).
- On a completed/stopped sweep with temporary failures, **Retry Failed** re-opens it
  so a fresh browser run re-attempts them.

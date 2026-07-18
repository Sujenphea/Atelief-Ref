# 165 — Analysis: backfill orchestration

## Summary

Phase C of feature 012: the seam that joins the three layers into a working
backfill. `AnalysisBackfill` walks the assets that still need analysis
(`assetsNeedingAnalysis`, AtelierCore), loads each blob (`MediaStore`), runs the
`AssetAnalyzer`, and persists the serialized result via
`AppServices.upsertAnalysis`.

- **`analyzeNextBatch(limit:)`** — analyzes up to `limit` pending assets and
  returns an `AnalysisBackfillOutcome` (analyzed / failed). Resumable + idempotent
  by construction: "still needs analysis" is a query, not a ledger, so analyzed
  assets drop out of the next batch and a re-run continues where it left off; a
  version bump re-queues stale rows. One bad asset (deleted mid-run, unreadable
  blob, decode failure) is counted and skipped — never fatal (the 004
  batch-outcome discipline).
- **`analyzeAll(batchSize:)`** — a one-shot drain that loops batches until the
  backlog is empty OR a batch makes no progress (only persistently-failing items
  remain, which would otherwise spin). A real scheduler prefers `analyzeNextBatch`
  on an idle cadence.

Scheduling (QoS / idle-priority / pause-on-user-activity) is deliberately the
app's concern (012: "genuinely idle-priority … never compete with ingest or the
canvas"); this type exposes the batch primitive the scheduler drives.

## Files changed

### AtelierIngestion
- `Analysis/AnalysisBackfill.swift` (new) — `AnalysisBackfill`,
  `AnalysisBackfillOutcome`, and the per-asset load→analyze→persist step.

### AtelierIngestionTests
- `AnalysisBackfillTests.swift` (new) — end-to-end over a real temp library (real
  blobs on disk): a batch analyzes all pending images and persists OCR/colors/phash;
  resumable batch-by-batch; idempotent second pass; `analyzeAll` drains in chunks;
  empty backlog does nothing.

## Migration notes

None. Pure additive orchestration + tests; no schema. Full AtelierIngestion suite
green (180 tests). Remaining 012 phase: OCR into the search union (Phase D), then
the app-side surfaces (swatch row, duplicates screen, color filter, backfill
scheduler) and video/suggested-tags follow-ons.

## Verify

- `swift test` (AtelierIngestion) — 180 tests green.

# 063 — Bulk import: drift canary + ingest-timing log (Phase 8)

Phase 8 of bulk import ([.docs/018](../.docs/018-bulk-import-plan.md)): the two
maintenance instruments — a drift canary that catches a platform response-shape
change before a live sweep silently yields nothing, and a lightweight ingest-timing
log that reveals the thumbnail stall which would justify the P16 lazy-tier lever.
Decisions 12A / 16A / [T12].

## Drift canary (extension)

- **`src/drift.js`** — pure invariant checks (`checkTimeline` / `checkBoardFeed` /
  `checkBoards`) that run a response through the REAL parsers and assert the signals
  the drivers depend on still exist (X: tweet entries → `media_key`-keyed items +
  a Bottom cursor; Pinterest: pins → mappable BulkItems + a bookmark). Returns
  `{ ok, problems, signals }` — naming exactly what drifted. Date-free, so it's
  deterministically unit-tested (the committed fixtures pass; mutated inputs — no
  cursor, stripped `images`, foreign payload — are each flagged).
- **`scripts/drift-check.js`** (opt-in, OUTSIDE CI via `npm run drift-check`) — wraps
  the checks with file loading (a committed fixture, or a fresh live capture the user
  saved into the gitignored `resources/`), a capture-age warning, and a non-zero exit
  on drift. Lives outside CI because a live check needs the user's logged-in session.
- **`test/fixtures/drift-baseline.json`** — the machine-readable stamp: capture date,
  `staleAfterDays`, and the volatile markers to re-verify (X queryId, Pinterest
  `X-APP-VERSION`). The README documents the workflow.

## Ingest-timing log (app)

- **`AtelierIngestion/IngestTiming.swift`** — a per-ingest phase breakdown (prepare /
  thumbnails / persist / total, + `tiersGenerated` and `blobExisted`). `thumbnails`
  is the metric of interest; `tiersGenerated == 0` is the P14 short-circuit fast path.
- **`IngestPipeline`** — an optional `timing` sink (default nil ⇒ measured from a
  monotonic `ContinuousClock` but not emitted, negligible cost). Emitted on each
  successful ingest.
- **App** — `IngestionModel` wires a sink that `os.Logger`-logs ONLY a thumbnail
  stall (thumbnail phase ≥ 250 ms), so the common fast path stays silent. A real bulk
  sweep that logs stalls is the measured trigger for P16 — which is added only then,
  not pre-emptively (the decision's whole point).

## Files changed

- New: `extension/src/drift.js`, `extension/scripts/drift-check.js`,
  `extension/test/drift.test.js`, `extension/test/fixtures/drift-baseline.json`,
  `AtelierIngestion/.../Pipeline/IngestTiming.swift`.
- `extension/package.json` (`drift-check` script), `test/fixtures/README.md`.
- `AtelierIngestion/.../Pipeline/IngestPipeline.swift` (timing marks + sink),
  `IngestPipelineTests.swift` (timing test), `AtelierRefs/.../IngestionModel.swift`
  (stall-logging sink).

## Verification

`npm test` **164** (+9 drift) green; `npm run drift-check` passes on the committed
fixtures (exit 0, no drift). `swift test` AtelierIngestion **85** (+1 timing) green;
`xcodebuild -scheme AtelierRefs` BUILD SUCCEEDED.

# 018 — Bulk Import: Plan (implementation)

> Phased build for [015-bulk-import-overview](./015-bulk-import-overview.md);
> shapes per [017-bulk-import-design](./017-bulk-import-design.md). Each phase is
> independently testable — the repo's one-chunk-per-step discipline. Decision tags
> (e.g. `[3A]`) map back to the overview. No production code until this plan is
> approved.

## Phase 0 — Reverse-engineer live specs *(optional; de-risks Phases 4–5)*
- [ ] Drive Claude-in-Chrome (`read_network_requests`) on the X Bookmarks page + a
  Pinterest board; capture current request shapes: X `Bookmarks`/`Likes` GraphQL
  `queryId` + `features` + headers; Pinterest `BoardsResource`/`BoardFeedResource`
  `data` param + `X-Pinterest-*` + cursor field.
- [ ] Save sanitized responses as the Phase 4–5 fixtures (`[T9]`), stamped with date
  + `queryId`/app-version (`[T12]`).

## Phase 1 — App-side foundation (`AtelierCore` + `AtelierServer`) — `[3A][11A][15A][14A][8A]` ✅ DONE ([changelog 056](../.change-log/056-bulk-import-job-ledger.md))
- [x] AtelierCore v3 migration: `job` + `job_item` (singular, matching schema
  convention), **indexed `source_id`** `[P14]` + `job.platform`; job/item services
  w/ per-item txns `[P15]`. (Known-sources answers from `job_item` across a
  platform's jobs — no extra column on `asset` needed.)
- [x] AtelierServer: `POST /jobs` (→ `jobId` + `caps` `[C8]`),
  `POST /jobs/{id}/complete`, `GET /jobs/{id}/known-sources`; extend ingest DTO with
  optional `jobId`+`sourceId`; **all through `CaptureAuth`** `[A4]` (+ CORS GET).
- [x] Tests `[T11]`: pure route handlers (fake `JobLedger`) + ephemeral-port
  integration + v3 migration + known-sources correctness + concurrent tagged POSTs
  + idempotent re-POST + **crash-consistency invariant** (count recomputed in-txn).
- [x] Verify: `swift test` green (AtelierCore 181 + AtelierServer 67); single-item
  capture unaffected.
- [x] App wiring: `IngestionModel.startCaptureEndpoint` constructs `JobRoutes` +
  passes `jobLedger: services`; `xcodebuild -scheme AtelierRefs` BUILD SUCCEEDED, so
  `/jobs` is live in the running app.

## Phase 2 — Extension shared refactors (DRY groundwork) — `[5A][6A][8A]` ✅ DONE ([changelog 057](../.change-log/057-extension-dry-refactors.md))
- [x] `ingestOne(provenance, {token, mp4Url, jobId, sourceId}, deps)` extracted;
  `sw.js:captureCore` refactored onto it `[C5]` — `sw.test.js` stays green (+ direct
  `ingestOne` tests). (mp4Url is passed in by the caller rather than a `resolveVideo`
  flag, since video detection needs harvest/context the bulk path won't have.)
- [x] `toOrigName` / `toOriginals` moved into `extractors/base.js`;
  `twitter.js`/`pinterest.js` reuse them `[C6]`. **`makeProvenance` deferred to
  Phase 4** (existing extractors have heterogeneous shapes — no current consumer;
  see changelog 057).
- [x] `config.js` added; `MAX_VIDEO_BYTES` relocated there `[C8]` (bulk overrides
  from the `/jobs` `caps` response when a sweep opens — wired in Phase 3).
- [x] Verify: `npm test` green (79 tests); single-item capture behaviour identical.

## Phase 3 — Bulk engine (pure state machine) — `[2A][7A][10A][13A][14A]` ✅ DONE ([changelog 058](../.change-log/058-bulk-engine-state-machine.md))
- [x] `BulkSource` seam consumed as an async iterator of `BulkItem`
  (`{ sourceId, mediaUrl, mediaUrlFallback, provenance, cursor }`); the driver
  implementations land in Phases 4–5.
- [x] `bulk-engine.js:runSweep`: cursor walk → dedup-skip vs in-memory known-set
  `[P14]` → bounded 2–3 concurrency + jitter + adaptive backoff `[P13]` → typed
  outcomes + fatal-halt `[C7]` → contiguous-watermark checkpoint to injected
  storage `[A1]` → relay via injected `relay` fn (production: `ingestOne` +
  `classifyIngestResult`, wired in Phase 6).
- [x] Pure/injectable — driver/relay/known-set/storage/`sleep`/`random` all
  injected; no chrome.*, no network, no real timers. `config.js` gains the bulk
  knobs `[C8]`.
- [x] Tests `[T10]`: terminator, dedup-skip (+ same-sweep dup), resume-from-cursor,
  contiguous checkpoint, retry requeue + backoff sequence, budget exhaustion,
  relay-throws, fatal halt (+ no-retry-on-halt, unreachable→halt), concurrent
  checkpoint ordering, progress, `classifyIngestResult` table.
- [x] Verify: `npm test` green (98 tests); single-item capture unaffected.

## Phase 4 — Pinterest driver (SW cursor replay; no MAIN-world) — `[9A]` ✅ DONE ([changelog 059](../.change-log/059-bulk-pinterest-driver.md))
- [x] `bulk-pinterest.js`: `BoardFeedResource` paginator (cursor → `-end-`, loop +
  empty-page guards) + `BoardsResource` enumeration; `X-CSRFToken` from `csrftoken`
  + `X-APP-VERSION` (runtime-scraped, passed in as driver input — not hardcoded);
  `mapPinterestPin()` reusing `base.js` `toOriginals()` + new `makeProvenance()`;
  `pinterestBoardDriver` conforms to the engine seam. (Board **sections** +
  `UserPinsResource` deferred — no fixture yet; same paginator shape when needed.)
- [x] Tests `[T9]`: committed fixtures + pure parse/paginate/map + a full
  driver × engine sweep + graceful driver-failure halt (120 tests green).
- [x] Verify: swept a real board end-to-end ([changelog 064](../.change-log/064-pinterest-pws-handler-403-fix.md))
  — live 403 root-caused to a missing `x-pinterest-pws-handler` (the sole gatekeeper),
  fixed, re-swept `complete`. *(Single-pin board; multi-page pagination still to be
  covered on a larger board — see 019 §T1.)*

## Phase 5 — X driver (page interception + MAIN-world) — `[4A][9A]` ✅ DONE ([changelog 060](../.change-log/060-bulk-twitter-driver.md))
- [x] MAIN-world `fetch` hook (`twitter-hook.js`) capturing `Bookmarks`/`Likes` JSON
  via `postMessage`; read-only, idempotent, never breaks the page. `mapTweet()` reuses
  `base.js` (`toOrigName({addIfAbsent})`) + `makeProvenance()` + `selectBestVideo()`;
  one BulkItem per media (keyed by `media_key`), quoted media excluded, video → poster
  + best-MP4 in rawMetadata. (`fetch`-only — X uses fetch for GraphQL; XHR added only
  if a real capture shows it.)
- [x] Tests `[T9]`: committed `Bookmarks` fixture + pure parse (items/cursor/terminator)
  + the hook (132 tests green).
- [x] `manifest.json` + content-script auto-scroll + `csrftoken` read — **landed in
  Phase 6** ([changelog 061](../.change-log/061-bulk-controller-sw-relay.md)).
- [ ] *(Stretch/deferrable: GDPR-archive upload path for Likes > ~3,200.)*
- [ ] Verify: sweep a small bookmarks set end-to-end. *(Manual — needs the Phase-6
  wiring.)*

## Phase 6 — Content-script loop + SW relay wiring — `[1A]` ✅ DONE ([changelog 061](../.change-log/061-bulk-controller-sw-relay.md))
- [x] Durable content-script controller (`runBulkSweep`) runs the engine; thin SW
  relay (`bulk-sw.js` + sw.js glue) proxies all localhost I/O; message protocol
  (`bulk-messages.js`); `/jobs` wrappers (`bulk-endpoint.js`); X push→pull source
  (`twitter-source.js`); `chrome.storage` checkpoint store. **Engine runs in the
  content script** (the verify criterion decides it); SW kept alive by item traffic.
- [x] MV3 module-loading solved: self-contained MAIN hook + dynamic-import loader +
  `web_accessible_resources`; manifest host_permissions + content scripts.
- [x] Cores unit-tested (152 tests); module graphs load; manifest validates.
- [ ] Verify: kill the SW mid-sweep → the loop continues; kill the tab → resume from
  checkpoint on reopen. *(Manual E2E — Phase 9.)*

## Phase 7 — App UI: progress + consent — `[4A]` + legal framing ✅ DONE ([changelog 062](../.change-log/062-bulk-progress-consent-controls.md))
- [x] Ledger-driven progress view (`BulkSweepsView`, a "Sweeps" tab): ingested /
  skipped / failed / total_estimate, polled live; `AppServices.listJobs` +
  `jobItemCounts`. Pause / resume / cancel controls that a RUNNING browser sweep
  honours via the per-item relay reply (`CaptureResponse.jobStatus` →
  `classifyIngestResult` halt) — not cosmetic.
- [x] Explicit **consent dialog**: own-data-only, human-paced, ToS/account-risk
  disclosure; gates the first sweep server-side (`JobRoutes` consent closure → 403
  `consent_required`) on the SAME persisted flag the in-app toggle writes.
- [x] Verify: Core 184 + Server 70 + extension 155 green; app BUILD SUCCEEDED.

## Phase 8 — Drift canary + timing — `[12A][16A]` ✅ DONE ([changelog 063](../.change-log/063-drift-canary-ingest-timing.md))
- [x] Opt-in `npm run drift-check` (outside CI): `src/drift.js` invariants run a
  fixture OR a fresh live capture through the real parsers, flagging exactly what
  drifted; `drift-baseline.json` stamps date + `queryId`/app-version, warns when stale.
- [x] Lightweight ingest-timing log: `IngestTiming` + an `IngestPipeline` sink; the
  app `os.Logger`-logs a thumbnail stall (≥250 ms) — the measured trigger for the P16
  lazy-tier lever (added only if a real sweep shows it).
- [x] Verify: extension 164 + AtelierIngestion 85 green; app BUILD SUCCEEDED.

## Phase 9 — End-to-end verification
- [ ] Manual sweep of a small real board + bookmarks set:
  - [ ] resumability (kill mid-sweep → resume, no duplicates)
  - [ ] dedup-skip (re-run → zero re-downloads)
  - [ ] pause-on-wall (simulate/observe a 429 or DOM wall → paused, resumable)
  - [ ] progress accuracy vs actual ingested assets
  - [ ] provenance correct on ingested assets (author/handle/originalURL/media)

## Suggested build order & sizing

Pinterest first (Phase 4) — SW-only, verifiable `-end-` cursor, no MAIN-world — to
prove the engine + ledger end-to-end before taking on X's interception + permission
surface (Phase 5). Phases 1–3 are prerequisites for both. Phases 7–8 can trail the
first working platform. Each phase ends green (`npm test` / `swift test`) before the
next.

## Follow-up docs on completion (per CLAUDE.md)
- [ ] `.change-log/` entry per phase (summary, files changed, migration notes).
- [ ] Update [009-mvp-status-overview](./009-mvp-status-overview.md) when the bulk
  path lands.

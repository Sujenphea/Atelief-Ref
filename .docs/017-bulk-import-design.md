# 017 — Bulk Import: Design (spec)

> The concrete seams, DTOs, schema, routes, and module shapes implementing the
> decisions in [015-bulk-import-overview](./015-bulk-import-overview.md). Plan:
> [018-bulk-import-plan](./018-bulk-import-plan.md).

## Component map

```
CONTENT SCRIPT (page context — durable while tab open)          [A1]
  BulkController: owns the sweep loop, checkpoints to chrome.storage
    ├─ BulkSource driver (per platform)                          [A2]
    │    · pinterest: (delegates enumeration to the SW replay)
    │    · twitter:   MAIN-world fetch/XHR hook + auto-scroll
    ├─ known-source set (loaded once at job open)                [P14]
    └─ per item → postMessage → SW
                    │
SERVICE WORKER (thin relay, kept alive by item traffic)          [A1]
  ├─ engine: bounded concurrency + jitter + backoff              [P13]
  ├─ ingestOne(provenance, {token, jobId, sourceId, resolveVideo}) [C5]
  └─ pinterest resource-API replay (fetch, credentials:'include')[A2]
                    │
ATELIER APP (loopback, network-free — hot path UNCHANGED)        [A3]
  AtelierServer: POST /jobs · POST /jobs/{id}/complete
                 GET /jobs/{id}/known-sources · per-item ingest (+jobId,sourceId)
  AtelierCore:  jobs / job_items tables (indexed source_id)      [P14/P15]
                IngestCoordinator (reused as-is)                 [P16]
```

`extractors/*` (single-item DOM extraction) stays; the bulk seam sits alongside it
and shares the pure helpers in `extractors/base.js`.

## The `BulkSource` seam (A2, C6)

One interface, an async iterator of enumerated items — the shared engine is blind
to platform:

```js
// A driver yields items; the engine handles pacing/skip/relay/checkpoint.
// async *enumerate(input, { cursor }): AsyncIterable<BulkItem>
// BulkItem = { sourceId, mediaUrl, mediaUrlFallback, provenance, cursor }
//   sourceId   — stable platform id (tweetId / pinId): dedup + skip key
//   cursor     — opaque resume token emitted after each item (checkpointed)
//   provenance — SAME SourceDraft shape the single-item extractors produce
```

- **pinterest driver** — SW-side; walks `BoardsResource` → `BoardFeedResource`
  (+ sections) → `UserPinsResource`; cursor = `options.bookmarks`, terminates at
  `-end-`. JSON→provenance via `mapPinterestPin()` reusing `base.js`
  `toOriginals()` + `makeProvenance()`.
- **twitter driver** — content-script-side; the `MAIN`-world hook captures
  `Bookmarks`/`Likes` responses as the page auto-scrolls; cursor = the
  `TimelineTimelineCursor` `Bottom` value. JSON→provenance via `mapTweet()` reusing
  `base.js` `toOrigName()` + `makeProvenance()`.

Shared pure helpers extracted into `extractors/base.js` (C6), reused by BOTH the DOM
extractors and the JSON mappers:
- `toOriginals(src)` — Pinterest `…/474x/…` → `…/originals/…` (was
  `pinterest.js:fullResolution`).
- `toOrigName(src)` — X `name=…` → `name=orig` (was `twitter.js:fullResolution`).
- `makeProvenance(fields)` — build + validate the `SourceDraft` shape.

## Shared `ingestOne()` (C5)

```js
// endpoint.js (or new ingest-core.js) — the single-item tail, reused by
// captureCore AND the bulk engine. Pure/injectable; returns a typed outcome.
async function ingestOne(provenance, { token, jobId, sourceId, resolveVideo }, deps)
//   → { outcome }  where outcome ∈ ItemOutcome (see C7)
```

`sw.js:captureCore` is refactored to call `ingestOne` with `resolveVideo:true`,
`jobId:null`. The bulk engine calls it with the job's `jobId` + item's `sourceId`;
`resolveVideo` is opt-in per config (default off for large sweeps — video
resolution is a per-item network cost).

## Error / outcome taxonomy (C7)

```
ItemOutcome = "ingested" | "deduped" | "skipped"
            | "retryableFailed"   // 429, timeout, 5xx  → requeue w/ backoff
            | "permanentFailed"   // 404, unsupported type → record, move on
SweepSignal = "continue" | "halt"  // halt on auth-expired / rate-limit wall
```

- One `permanentFailed`/`retryableFailed` NEVER aborts the sweep; it is recorded in
  `job_items.status`.
- `halt` is raised by the driver (fatal auth / DOM "something went wrong" wall) or
  by repeated `retryableFailed` past a backoff ceiling; the controller checkpoints,
  pauses, and surfaces "paused — platform is throttling, resume later?".
- `skipped` = `sourceId` already in the known-source set (P14) → no download.

## App-side schema (A3, P14, P15)

```
jobs(
  id TEXT PRIMARY KEY, platform TEXT, scope TEXT,        -- e.g. "pinterest"/"board:123"
  status TEXT,                                           -- open | paused | complete | halted
  total_estimate INTEGER NULL, ingested_count INTEGER,
  created_at TEXT, updated_at TEXT )

job_items(
  job_id TEXT, source_id TEXT, source_url TEXT,
  status TEXT,                                           -- ItemOutcome
  blob_hash TEXT NULL,                                   -- set on ingested
  updated_at TEXT,
  PRIMARY KEY (job_id, source_id) )

-- P14: skip lookup must be O(1) server-side.
INDEX ix_job_items_source_id ON job_items(source_id);
```

`source_id` also recorded on the asset's provenance so `known-sources` can answer
across jobs (an item ingested in a prior sweep is skippable in the next). Per-item
writes are single transactions (P15, matching ingestion P15 — WAL, cheap, isolated).

## Routes (A3, A4)

All routed through the existing `CaptureAuth` middleware (token + Origin allowlist)
— NO new auth code.

- `POST /jobs` → `{ jobId, caps }` where `caps` = the server's body/video byte
  limits (C8 — the extension reads these instead of hardcoding `MAX_VIDEO_BYTES`).
- per-item ingest (existing route) → DTO gains **optional** `jobId`, `sourceId`;
  when present, upserts a `job_items` row and bumps `jobs.ingested_count`.
- `GET /jobs/{id}/known-sources` → `{ sourceIds: [...] }` (one indexed query;
  loaded once by the controller into the in-memory skip set).
- `POST /jobs/{id}/complete` → closes the job (also reachable via idle timeout).

## Config (C8)

`extension/src/config.js` — single source of truth for tuning: `MAX_CONCURRENCY`
(2–3), `PACING_MS` base + jitter, `BACKOFF_BASE_MS`/`BACKOFF_MAX_MS`, `PAGE_SIZE`,
`UNSENT_QUEUE_MAX`. Cross-boundary byte caps are NOT here — they come from the
`/jobs` `caps` response.

## Permissions (A4)

`manifest.json` additions: persistent `host_permissions` for `*://*.x.com/*`,
`*://*.twitter.com/*`, `*://*.pinterest.com/*`; `world:'MAIN'` script injection used
**only** for the X hook. `ct0` read via content script (no `cookies` permission).
Sweep remains user-gesture-initiated.

## Reused unchanged

`IngestCoordinator` (P16), `MediaStore` content-addressing (dedup backstop),
`DirectInputReader.remoteInput`, the `Blob`-streamed video POST path
(`downloadAndIngestVideo`), `net.js:fetchWithTimeout`.

## Phase 0 — captured live specs (verified 2026-07-03, via Claude-in-Chrome)

Request shapes/queryIds/app-version were captured live; **response bodies could NOT
be** — the browser tool auto-redacts any result containing real account data, and
the network reader exposes URLs/status but not headers/bodies. Response-shape
fixtures come from a user-assisted DevTools pass (see plan Phase 0). Everything
below marked **[drift-prone]** feeds the T12 drift canary and MUST be captured at
runtime, never hardcoded.

### X / Twitter — timeline GraphQL (captured from a live `Likes` 200)
- **Endpoint:** `GET https://x.com/i/api/graphql/{queryId}/{Op}` where `Op` ∈
  `Bookmarks` | `Likes`. **[drift-prone] queryId** rotates per operation
  (observed Likes queryId `tl9f_I0xyREhFd5KMzuO7w`, 2026-07-03; Bookmarks has its
  own).
- **variables** (URL-encoded JSON): `Likes` needs `userId` (the profile's id);
  `Bookmarks` does not (it's the authed user). Common: `count: 20` (page size),
  `includePromotedContent:false`, `withVoice:true`; **pagination adds `cursor`**
  (absent on page 1) = the `TimelineTimelineCursor` `Bottom` value.
- **[drift-prone] features:** a ~40-key boolean blob (URL-encoded JSON) +
  `fieldToggles={withArticlePlainText:false}`. Large and volatile — **this is the
  concrete evidence for choosing interception (2b) over forging**: the driver must
  inherit X's own `features`/`queryId`/`x-client-transaction-id` from the page's
  real request, not reconstruct them.
- **Design impact:** the MAIN-world hook targets `…/i/api/graphql/*/{Bookmarks,Likes}`
  responses; the empty-bookmarks case fires NO fetch (nothing to intercept) — the
  content-script must handle "no timeline request observed" as empty, not as a hang.

### Pinterest — resource API (captured from a live `BoardsResource` attempt)
- **Endpoint:** `GET https://{host}/resource/BoardsResource/get/?source_url=…&data=…`
  (host is regional — see below). `data` = URL-encoded JSON
  `{options:{privacy_filter, sort, field_set_key, filter_stories, username,
  page_size:25}, context:{}}`. Verified from the live network log.
- **[drift-prone] `X-APP-VERSION`** is REQUIRED — a request with a bogus value 403s.
  Observed value `1df0da9` (2026-07-03), **scraped at runtime** from an inline script
  via `/app_version"\s*:\s*"([a-f0-9]{6,12})"/` — validates the runtime-scrape
  decision.
- **Auth:** `csrftoken` cookie present (32 chars) → `X-CSRFToken`; HttpOnly session
  cookie auto-sent by `credentials:'include'`.
- **⚠️ Forging is non-trivial:** a page-context `fetch` with valid `csrftoken` +
  `X-APP-VERSION` + `X-Pinterest-AppState` still **403'd**. The resource endpoint
  needs the *exact* client header set (likely `X-Pinterest-PWS-Handler` /
  source-url headers, still unverified). **Design impact:** the Pinterest SW driver
  may need to **capture headers from a real intercepted request** rather than forge
  them — i.e. lean toward the same interception posture as X. Confirm the missing
  header(s) during Phase 4 before committing to pure forging.

### Cross-cutting findings
- **Regional host — NO bug (verified 2026-07-03):** session resolved to
  `REDACTED`. An initial read *suspected* `extractors/pinterest.js:match()`
  wouldn't match regional subdomains, but running it proves otherwise:
  `hostIs` already suffix-matches (`host.endsWith("." + domain)`), so
  `pinterest.match("https://REDACTED/…")` → `true`, and the manifest
  wildcard `*://*.pinterest.com/*` covers regional hosts. (`pinterest.co.uk` is a
  distinct TLD, correctly listed separately.) **No change needed.** The real bulk
  implication: the Pinterest SW driver must issue `/resource/…` calls against the
  **active tab's origin** (e.g. `REDACTED`), NOT a hardcoded
  `www.pinterest.com`, so cookies/CSRF match the session host.
- **Tooling limit for fixtures:** Claude-in-Chrome cannot exfiltrate authed response
  bodies (by design). Response-shape fixtures for BOTH platforms must be captured by
  the user via DevTools (copy the 200 response JSON), then sanitized. Recorded as
  plan Phase 0's user-assisted step.

### Fixtures still needed (user-assisted DevTools, T9)
- Pinterest: one `BoardFeedResource` 200 response (a board with pins) + one
  `BoardsResource` 200 response.
- X: one `Bookmarks` (or `Likes`) 200 response with ≥1 tweet incl. photo + video
  entities, to shape the tweet→provenance mapper (image `name=orig`, video variants).

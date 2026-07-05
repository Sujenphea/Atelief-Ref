# 015 — Bulk Import (Bookmarks / Boards): Overview (decisions + index)

> The deferred **Phase-2 backfill** flagged in [011-capture-extension-overview](./011-capture-extension-overview.md)
> ("bulk board/likes backfill (Phase 2)"). Where the capture extension saves **one
> post/pin per gesture**, bulk import sweeps a user's **entire** saved set — X
> **Bookmarks/Likes**, Pinterest **boards/pins** — into the same content-addressed
> store, through the SAME per-item ingest pipeline
> ([007-ingestion-overview](./007-ingestion-overview.md)).

Produced via an interactive Architecture → Code Quality → Tests → Performance
review. Every fork was chosen by the user (all "A" options). Research behind the
mechanism choices: [016-bulk-import-research](./016-bulk-import-research.md).
Spec: [017-bulk-import-design](./017-bulk-import-design.md).
Plan: [018-bulk-import-plan](./018-bulk-import-plan.md).

## The core idea

A bulk sweep is **the existing single-item pipeline run many times, orchestrated
durably** — not a new ingestion path. The winning mechanism per platform (see
research) is: *let the site's own web client make its paginated data calls while
we ride the authenticated session*, then feed the results into today's
extension-fetches-bytes → localhost-POST → content-addressed ingest loop.

- **X / Twitter** — auto-scroll + **GraphQL response interception** (a `MAIN`-world
  hook reads the `Bookmarks`/`Likes` JSON the page already fetches). Inherits X's
  valid `queryId` / `features` / `x-client-transaction-id` for free; gets original
  image URLs **and** video-variant URLs.
- **Pinterest** — **internal resource-API cursor replay** from the service worker
  (`BoardsResource` → `BoardFeedResource` → cursor to `-end-`). Deterministic and
  **verifiable-complete** (a real terminator), full-res via the existing
  `/originals/` rewrite.

## Decisions (16, all chosen interactively)

### Architecture
- **A1 (1A) — Content-script drives, SW relays.** The long sweep loop lives in the
  content script (durable while the tab is open; not subject to the MV3 SW
  ~30s-idle / 5-min-hard limits). The SW is a thin per-item relay whose message
  traffic keeps it alive; **all** sweep state is checkpointed to
  `chrome.storage.local`. No keep-alive hacks.
- **A2 (2A) — Shared engine + per-adapter drivers.** One `BulkSource` seam yields an
  async stream of `{sourceId, mediaUrl, provenance}`; pacing, dedup-skip,
  checkpoint, and relay are written ONCE. Only the irreducible difference — X page
  interception vs Pinterest SW replay — lives behind the seam.
- **A3 (3A) — Two-tier state + a job ledger.** Enumeration cursor + unsent queue in
  `chrome.storage.local` (extension owns); a durable `jobs`/`job_items` table in
  `AtelierCore` (app owns) plus a thin `POST /jobs` open/close handshake and
  `GET /jobs/{id}/known-sources`. Existing per-item POST is kept (server is
  network-free / rides no auth session, so it CANNOT fetch auth-walled CDNs — bytes
  must come from the extension); no server-side batch-fetch endpoint.
- **A4 (4A) — Least-privilege permissions.** Add persistent `host_permissions` for
  `x.com`/`pinterest.com` + `world:'MAIN'` injection **scoped to X only**; read
  `ct0` via a content script (no `cookies` permission); route all `/jobs` endpoints
  through the existing `CaptureAuth` (token + Origin) — never fork the auth path.

### Code quality
- **C5 (5A) — Shared `ingestOne()`.** Extract the single-item ingest tail
  (fetch bytes → build request → POST → interpret) into
  `ingestOne(provenance, {token, jobId, sourceId, resolveVideo})`, consumed by BOTH
  `sw.js:captureCore` and the bulk engine. Video resolution becomes an opt-in flag.
- **C6 (6A) — Shared pure provenance helpers.** Pull the `name=orig` / `/originals/`
  rewrites and the provenance shape/validation out of the DOM extractors into
  `extractors/base.js`; thin per-source JSON→provenance mappers reuse them.
- **C7 (7A) — Typed per-item outcomes + halt.** `{ingested, deduped, skipped,
  retryableFailed, permanentFailed}` per item + a sweep-level `halt` on fatal
  auth-expired / rate-limit-wall; retryable items requeue with backoff; every
  outcome persists to `job_items.status`. One bad item never aborts the sweep.
- **C8 (8A) — Centralized config; server surfaces its own caps.** One extension
  `config.js` for tuning; cross-boundary caps (body/video) are returned by the
  server in the `/jobs` open response so the extension reads them — killing the
  existing hand-synced `MAX_VIDEO_BYTES` smell rather than adding a second one.

### Tests
- **T9 (9A) — Fixtures + pure parse for the drivers.** Sanitized real GraphQL /
  resource responses as committed fixtures; the pure parse→paginate→map→provenance
  logic is unit-tested offline; driver I/O (fetch / MAIN-world hook) is injectable.
- **T10 (10A) — Pure engine state machine.** The sweep engine is
  pure/injectable (fake driver/clock/storage); table-driven tests for cursor→
  terminator, dedup-skip, checkpoint→resume, retry requeue, and fatal→halt.
- **T11 (11A) — Two-layer ledger tests + invariant.** Pure `/jobs` route handlers +
  ephemeral-port integration + AtelierCore migration/persistence; known-sources
  correctness, concurrent tagged POSTs, idempotent re-POST, and a **crash-mid-sweep
  consistency invariant** (the `job_items` analogue of the ingestion A2 invariant).
- **T12 (12A) — Fixtures in CI + a live drift canary.** Deterministic fixture tests
  in CI PLUS an opt-in `drift-check` script (NOT in CI) that hits one real page and
  asserts the response still parses — the early warning for `queryId` rotation /
  header changes. Fixtures stamped with capture date + observed `queryId`/version.

### Performance
- **P13 (13A) — Bounded 2–3 concurrency + jitter + adaptive backoff.** The account
  at risk is the user's own logged-in one, so conservative pacing is a
  correctness/safety requirement. Keep `Blob` streaming for video; cap in-flight
  base64 images to the concurrency limit. Values live in `config.js`.
- **P14 (14A) — Load the known-source set once.** A single `known-sources` query at
  job open, held in memory and updated during the sweep → O(1) local skip checks,
  no N+1. Requires an index on the source-id column.
- **P15 (15A) — Per-item `job_items` transactions.** Consistent with ingestion P15
  (WAL, cheap, per-item failure isolation, truthful live progress). The write is
  negligible next to the media download.
- **P16 (16A) — Reuse the bounded `IngestCoordinator`; measure first.** It already
  caps concurrency, decodes-to-thumbnail-size, and gives POST backpressure. The
  lazy-largest-tier optimization P16 anticipated is added ONLY if a measured stall
  appears (a timing log makes it visible). No premature bulk queue.

## Scope

**In:** X Bookmarks + Likes; Pinterest boards + board pins (+ sections, secret
boards via session); resumable job with progress + consent; download-skip;
account-safe pacing.

**Out (deferred):** background sweep while the app is closed; Instagram/Cosmos bulk
(single-item only for now); the GDPR-archive upload path for X Likes beyond the
~3,200 web wall (secondary, Phase 5 stretch); official-API "clean" importers
(X API v2 pay-per-use, Pinterest API v5) as an alternative sanctioned mode.

## Legal posture (summary; see research §5)

Defensible as scoped — the user's **own** saved data, **own** session, **local
only**, no redistribution (personal data portability; *hiQ* narrows CFAA). The real
exposure is **enforceable ToS "no automated access" clauses** (logged-in own-account
access is what *Meta v. Bright Data* binds), and the realistic worst case is
**account throttling/suspension, not litigation** — which is exactly why P13's
pacing and the A4 user-gesture/consent framing are risk mitigations, not politeness.
Not legal advice; counsel review before any commercial ship.

## Verification

`npm test` green in `extension/` (drivers via fixtures, engine via fakes);
`swift test` green in `AtelierServer` + `AtelierCore` (ledger two-layer + invariant);
a manual sweep of a small real board + bookmarks set proves resumability
(kill → resume), dedup-skip (re-run → no re-download), pause-on-wall, and accurate
progress.

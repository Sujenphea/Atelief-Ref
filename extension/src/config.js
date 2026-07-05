// Atelier Capture — extension tuning constants (single source of truth, 8A).
//
// The one place client-side knobs live, so they don't scatter across modules and
// drift. The cross-boundary byte caps here are a client-side OPTIMISATION only —
// the app server enforces its own caps regardless, so a stale value can never
// cause a bad ingest, only a slightly-late rejection. For a bulk sweep the
// extension reads the server's AUTHORITATIVE caps from the `POST /jobs` open
// response and overrides these; single-item capture uses these defaults. This
// removes the previously hand-synced `MAX_VIDEO_BYTES` copy in `sw.js`.

/** Reject a video whose declared size exceeds this before downloading it. Mirrors
 * the server's `CaptureServer.defaultMaxVideoBodyBytes` (the server is the
 * authority); kept here so a doomed huge clip isn't fully downloaded only for the
 * server to 413 it. */
export const MAX_VIDEO_BYTES = 512 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Bulk-sweep engine knobs (Phase 3, [C8][P13]). The bulk engine (bulk-engine.js)
// reads these; every one is overridable per-run via `runSweep(..., { config })`
// so tests pin deterministic values. They govern PACE (how human-paced the sweep
// is), RESILIENCE (retry/backoff), and PARALLELISM — never correctness: the app's
// dedup + the job ledger make re-processing idempotent, so a stale knob only
// changes speed, never what gets ingested.
// ---------------------------------------------------------------------------

/** Concurrent in-flight items. Deliberately small (2–3): a bulk sweep should look
 * like brisk human browsing, not a scraper hammering the origin. */
export const MAX_CONCURRENCY = 3;

/** Base gap before each item's relay, so the sweep is paced rather than bursty. */
export const PACING_MS = 800;

/** Random extra delay in [0, PACING_JITTER_MS) added to each gap — breaks up a
 * perfectly periodic request cadence (a bot tell). */
export const PACING_JITTER_MS = 700;

/** First retry backoff; doubles each attempt (`BACKOFF_BASE_MS * 2^(n-1)`). */
export const BACKOFF_BASE_MS = 1000;

/** Backoff ceiling — a single item never waits longer than this between retries. */
export const BACKOFF_MAX_MS = 30_000;

/** Per-item retry budget for a `retryableFailed` outcome. On exhaustion the item
 * is recorded `retryableFailed` (a later sweep re-attempts it) and the sweep moves
 * on — one bad item NEVER aborts the sweep `[C7]`. Distinct from a `halt` signal
 * (auth wall / app unreachable), which DOES pause the whole sweep. */
export const MAX_ITEM_RETRIES = 4;

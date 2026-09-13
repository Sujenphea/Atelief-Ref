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

/** Base gap before each X `TweetDetail` thread-expansion request, plus its jitter
 * (the same shape as `PACING_MS` / `PACING_JITTER_MS`). Thread expansion is a SECOND
 * request stream that the engine's item pacing doesn't cover — the engine paces
 * relays to the local app, while these go to X — so without its own gap a page of
 * bookmarks would fire a burst of conversation reads, which is precisely the shape
 * the item pacing exists to avoid. Slightly gentler than the item pace because these
 * hit the origin rather than loopback. */
export const THREAD_PACING_MS = 1200;
export const THREAD_PACING_JITTER_MS = 900;

// ---------------------------------------------------------------------------
// rednote note-open expansion (098 D4 / R13). The cost of K3b, stated as numbers
// rather than as a warning: one SPA note-open per note, each one a page-driven
// request against a site that already fingerprints browsing.
// ---------------------------------------------------------------------------

/** The CEILING on note-opens in one sweep. 098's cost table sizes a large board at
 * ~400 notes, so this admits a whole board once and refuses to let a pathological or
 * unbounded board turn one click into thousands of opens. Exhausting it is NOT a halt:
 * the remaining notes keep their cover item, the cover pass finishes normally, and the
 * sweep reports itself PARTIAL rather than pretending it expanded everything. A later
 * re-sweep picks up where it stopped, because a note that only ever produced a cover has
 * no `<note_id>:<index>` child for the known-set pre-check to skip it by. */
export const NOTE_OPEN_BUDGET = 400;

/** Base gap before each note-open, plus its jitter — the same shape as `PACING_MS` /
 * `PACING_JITTER_MS` and the same reason as `THREAD_PACING_MS`: this is a SECOND request
 * stream the engine's item pacing does not cover (the engine paces relays to the local
 * app; these drive the origin). Gentler than X's, because rednote refused a scripted
 * request with a 461 during development and 30 note-opens a minute is not browsing. */
export const NOTE_OPEN_PACING_MS = 1800;
export const NOTE_OPEN_PACING_JITTER_MS = 1200;

/** How long to wait for a note's own `POST /v1/feed` response after opening it, and how
 * often to look. A note that never answers must cost this much and no more: the whole
 * point of a budget is undone by one open that hangs the sweep. On timeout the note keeps
 * its cover and the sweep counts a degradation. */
export const NOTE_OPEN_TIMEOUT_MS = 8000;
export const NOTE_OPEN_POLL_MS = 250;

/** How long to let the SPA settle after a click that opens (or closes) a note. Short —
 * it is only there so the click and the route change are not issued in the same tick;
 * the real waiting is `NOTE_OPEN_TIMEOUT_MS` against the intercepted response. */
export const NOTE_OPEN_SETTLE_MS = 400;

/**
 * How many VIDEO candidates one item may try before it gives up (098 D5 / 020 rule 2).
 *
 * The 422 from `/ingest-video` means "advance the ladder", and a ladder is now plural in
 * two directions at once: rungs, and each rung's `master_url` + `backup_urls[]`. Without a
 * ceiling a note offering four buckets of several rungs each, every one with backups, turns
 * ONE item into dozens of full video DOWNLOADS — each up to the 512 MB cap — before it is
 * allowed to fall back to its cover. That is a retry storm against a site that already
 * fingerprints browsing (098 D8), and the bytes are the expensive part, not the requests.
 *
 * Four, because the only ladder ever captured is one rung of two urls: four admits the
 * whole of it plus a second rung's master and backup, which is two genuine codec attempts.
 * Past that the honest answer is 020's — keep the cover still and record a typed skip.
 */
export const MAX_VIDEO_CANDIDATES = 4;

/** Per-item retry budget for a `retryableFailed` outcome. On exhaustion the item
 * is recorded `retryableFailed` (a later sweep re-attempts it) and the sweep moves
 * on — one bad item NEVER aborts the sweep `[C7]`. Distinct from a `halt` signal
 * (auth wall / app unreachable), which DOES pause the whole sweep. */
export const MAX_ITEM_RETRIES = 4;

// ---------------------------------------------------------------------------
// Per-platform pacing overrides (002 · 13A). The globals above are the default;
// a platform listed here overrides them so a more detection-sensitive site sweeps
// gentler. `engine` keys override the `runSweep` config (concurrency + pacing).
// A platform NOT listed inherits the globals (X and Pinterest keep today's values).
// ---------------------------------------------------------------------------

/** Instagram sweeps gentler than X/Pinterest by construction (Meta's anti-bot is the
 * dominant risk, 002 §account-safety) — and O2 replays the saved-feed endpoint directly
 * (a synthetic request pattern), so pacing matters MORE, not less. Lower concurrency +
 * longer pacing; under the 1A per-media fan-out a carousel takes one paced slot per image,
 * which also throttles how fast the driver pages the feed (a page fetch only fires once
 * its items drain). Slow is the safe direction. */
export const PLATFORM_PACING = Object.freeze({
  instagram: {
    engine: { MAX_CONCURRENCY: 2, PACING_MS: 1500, PACING_JITTER_MS: 1200 },
    // Re-sweep early-stop (14A): after this many CONSECUTIVE already-known items, a FRESH
    // sweep whose PRIOR run closed clean stops — it has reached previously-synced territory
    // on IG's saved feed. Precondition VERIFIED LIVE (2026-07-16): the feed is ordered
    // newest-SAVE-first — a freshly-saved post lands at index 0 and pushes the rest down in
    // order (and it is NOT post-time ordered), so once a run of known items begins the tail
    // stays monotonically known. ~1 page of singles of margin absorbs minor feed reordering;
    // carousels count per-image, so this is comfortably conservative. IG-only — X/Pinterest
    // re-walk in full. The controller arms it ONLY on a fresh + prior-clean sweep.
    reSweep: { STOP_AFTER_CONSECUTIVE_SKIPS: 30 },
  },
  rednote: {
    // Instagram's numbers, for the same reason: the live probe found rednote running an
    // active risk-control layer (`as.rednote.com/api/sec/v1/shield/webprofile`,
    // `xhsFingerprintV3`, an `x-rap-param` signature blob) that already refused a scripted
    // request with HTTP 461. Sweep gently or not at all.
    engine: { MAX_CONCURRENCY: 2, PACING_MS: 1500, PACING_JITTER_MS: 1200 },
    // The note-open budget + pacing for K3b's expansion pass, threaded from here so the
    // knobs for a platform live in one block. References the constants above rather than
    // restating them — one value, two access paths, nothing to drift.
    noteOpen: {
      BUDGET: NOTE_OPEN_BUDGET,
      PACING_MS: NOTE_OPEN_PACING_MS,
      PACING_JITTER_MS: NOTE_OPEN_PACING_JITTER_MS,
      TIMEOUT_MS: NOTE_OPEN_TIMEOUT_MS,
      POLL_MS: NOTE_OPEN_POLL_MS,
      SETTLE_MS: NOTE_OPEN_SETTLE_MS,
    },
    // NO `reSweep` — early-stop stays DISARMED (098 R1/D8). Instagram earned that
    // optimisation with a live-verified precondition: its saved feed is newest-SAVE-first,
    // so a run of known items means the tail is known too. Board ordering is unverified,
    // and copying the optimisation without the precondition silently truncates sweeps.
  },
});

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

/** How many note-opens rednote must refuse IN A ROW before the sweep halts (020's
 * `xsec_token`-expiry hazard, changelog 500).
 *
 * A board-feed refusal is unambiguous — the feed is the SESSION talking, and one is worth
 * stopping a sweep for. A note-detail refusal is not, and the ambiguity is the whole of
 * this number. Two different things can produce it and they want opposite answers:
 *
 *   · the SESSION was flagged (the 461 shape, 098 D1) — halt, because every further open
 *     is another request against an account rednote has already turned away;
 *   · the NOTE's `xsec_token` died (020, "Risks & edge cases") — degrade this one note to
 *     its cover, because the board's other 399 notes are fine and re-sweeping fixes it.
 *
 * **Nothing in any live run has yet shown which body a dead token produces**, so the two
 * cannot be told apart by their SHAPE. They can be told apart by their RHYTHM: a flagged
 * session refuses everything, while a stale credential is a fact about one note (or one
 * feed page's worth) with working notes on either side. So the discriminator is a RUN of
 * refusals with no answer in between, and this is how long a run has to be.
 *
 * Three, because the cost of being wrong is asymmetric and small in both directions. Too
 * high and a flagged session gets a handful of extra opens — seconds of pacing, not a
 * treadmill. Too low and one dead credential ends a 400-note sweep, which is what it did
 * before this existed. It is deliberately NOT threaded through `PLATFORM_PACING`, for the
 * reason `NOTE_REACH_*` is not: it describes one SPA's one refusal behaviour, there is no
 * second platform to vary it for, and a second access path is only somewhere for a typo to
 * fall back to a default and look like it worked. */
export const NOTE_DETAIL_REFUSAL_STREAK = 3;

// ---------------------------------------------------------------------------
// rednote NOTE REACH (098 2A / changelog 497). The board grid is VIRTUALISED — a live probe
// on 2026-09-14 counted 13 mounted note cards against a feed page of 37-38 and a board of
// 116 — so a note can only be opened while its card is in the DOM. These bound the WALK the
// expansion pass takes down each page to mount them.
//
// Like the feed reset's numbers and unlike `noteOpen`'s, they are NOT threaded through
// `PLATFORM_PACING`: they describe one SPA's one virtualised grid, there is no second
// platform to vary them for, and a second access path would add nothing but somewhere for a
// typo to fall back to a default and look like it worked.
// ---------------------------------------------------------------------------

/** How far one step moves the viewport, as a fraction of the viewport's own height. Under
 * 1 on purpose: a full-screen step would place the new band exactly where the old one was
 * and could skip a row of cards between two mounts, and the cost of the overlap is one
 * extra step per page, not one extra note-open. */
export const NOTE_REACH_STEP_RATIO = 0.8;

/** How long to let the grid re-render after a step before asking which cards are mounted.
 * A virtualiser mounts on its own scroll handler, usually on the next frame; this is the
 * same "do not issue the next thing in the same tick" settle as `NOTE_OPEN_SETTLE_MS`, a
 * little longer because a mount is more work than a route change's first paint. */
export const NOTE_REACH_SETTLE_MS = 600;

/** The CEILING on steps spent walking ONE page down. The stepper stops on its own when it
 * reaches the foot of the document, which is the honest terminator; this is the guard for
 * a page that keeps growing under us (a lazy grid that renders as you go) so that one page
 * can never hold the sweep for ever. A feed page is 37-38 notes ≈ 3-4 screenfuls, so 12
 * steps is several times what a page should need. Hitting it retires the rest of the page
 * to covers — the same outcome as reaching the foot, reached the same way. */
export const NOTE_REACH_ROUNDS = 12;

// ---------------------------------------------------------------------------
// rednote in-page FEED RESET (098 / changelog 494). The board feed pages FORWARD only, so
// a sweep that does not hold the opening slice can never fetch it — 493 refuses such a run,
// and these numbers bound the attempt to put the feed back at its start before it does.
// ---------------------------------------------------------------------------

/** How long to wait for the hook's REPLAY before concluding the board is not at its start.
 * The controller posts the replay request and returns; the buffered responses come back one
 * `postMessage` task each. This is the grace 493's timing note is about, moved earlier: too
 * short and a freshly-loaded board is navigated for nothing (an automation footprint against
 * a site that already fingerprints browsing); too long and every mid-scrolled sweep pays it
 * before the reset starts. A fresh board does NOT pay it — the wait ends the moment the
 * opening slice lands. */
export const FEED_RESET_GRACE_MS = 1500;

/** How long to wait for the opening slice AFTER the reset has been driven, and how often to
 * look. `NOTE_OPEN_TIMEOUT_MS`'s reasoning, for the same kind of wait: a route change that
 * never produces its fetch must cost this much and no more, and then the sweep falls into
 * 493's refusal rather than sweeping on from the middle. */
export const FEED_RESET_TIMEOUT_MS = 8000;
export const FEED_RESET_POLL_MS = 250;

/** How long to let the SPA settle after the click that leaves the board, and again after
 * the `history.back()` that returns to it. LONGER than `NOTE_OPEN_SETTLE_MS`, which is the
 * only reason it is not that constant: a note-open is an overlay over a board that stays
 * mounted, while this is a whole view swap in each direction, and the settle is what the
 * "did we actually route?" check reads. */
export const FEED_RESET_SETTLE_MS = 1200;

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

/**
 * How often a running sweep pings `POST /jobs/{id}/progress` to say it is alive.
 *
 * The app pauses any `open` job whose `updated_at` is older than its
 * `IngestionModel.staleSweepSeconds` — 90 seconds — and until this existed the ONLY
 * thing that bumped `updated_at` was an item being RELAYED. A live sweep is quiet for
 * far longer than 90s at a time: a dedup skip takes no relay and no pacing, and
 * rednote's note-open pass spends `NOTE_OPEN_PACING_MS` + jitter per note plus up to
 * `NOTE_OPEN_TIMEOUT_MS` waiting for each one, relaying nothing whenever the notes it
 * opens hold only already-known items. So the app paused jobs underneath running
 * sweeps, the next relay came back `jobStatus: "paused"`, and the sweep halted itself
 * two items into a 116-note board with no error to show for it.
 *
 * 30s: a THIRD of the app's window, so two consecutive pings can be lost — a torn-down
 * SW, a busy tab, a slow loopback — before a live sweep looks dead. Going higher buys
 * nothing (the ping is one small POST to 127.0.0.1) and eats the margin; going much
 * lower only adds traffic. It must stay WELL under 90s whatever else changes: the two
 * numbers sit either side of a process boundary and cannot be one constant, so the
 * app's `staleSweepSeconds` names this one and this one names it back.
 */
export const SWEEP_HEARTBEAT_MS = 30_000;

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

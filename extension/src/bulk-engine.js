// Atelier Capture — the bulk-sweep engine (Phase 3, [2A][7A][10A][13A][14A]).
//
// A pure, platform-blind state machine. A per-platform `BulkSource` DRIVER yields
// enumerated items (an async iterator); the engine handles everything else:
//   · dedup-skip vs an in-memory known-source set                         [P14]
//   · bounded concurrency + human pacing/jitter + adaptive per-item backoff [P13]
//   · a typed per-item outcome, with retry-with-backoff for transient fails [C7]
//   · a fatal `halt` (auth wall / app unreachable) that pauses the sweep    [C7]
//   · resumable cursor checkpointing to a caller-supplied store            [A1]
//   · per-item relay via the caller's `relay` fn (production: `ingestOne`) [C5]
//
// EVERYTHING is injected — driver, relay, known-set, storage, `sleep`, `random` —
// so the whole machine runs under `node --test` with no chrome.*, no network and
// no real timers (bulk-engine.test.js drives it with fakes).
//
// A `BulkItem` (what the driver yields):
//   { sourceId, mediaUrl, mediaUrlFallback, provenance, cursor }
//     sourceId — stable platform id (tweetId / pinId): the dedup + skip key.
//     cursor   — opaque resume token; the engine checkpoints the cursor of the
//                last CONTIGUOUSLY-completed item so a resume never skips a gap.

import {
  MAX_CONCURRENCY, PACING_MS, PACING_JITTER_MS,
  BACKOFF_BASE_MS, BACKOFF_MAX_MS, MAX_ITEM_RETRIES,
} from "./config.js";

/** The five terminal per-item outcomes recorded in the job ledger ([C7]). */
export const OUTCOMES = Object.freeze({
  ingested: "ingested",
  deduped: "deduped",
  skipped: "skipped",
  retryableFailed: "retryableFailed",
  permanentFailed: "permanentFailed",
});

/** Exponential backoff for a retry `attempt` (1-based), capped. attempt 1 → base,
 * 2 → 2·base, 3 → 4·base … never exceeding `BACKOFF_MAX_MS`. */
export function computeBackoff(
  attempt,
  { BACKOFF_BASE_MS: base = BACKOFF_BASE_MS, BACKOFF_MAX_MS: max = BACKOFF_MAX_MS } = {}
) {
  return Math.min(base * Math.pow(2, attempt - 1), max);
}

function isAuthWall(status) {
  // A hard auth failure means the SESSION is unauthorized, not just this item — the CDN
  // cookie expired or the app token is wrong. Continuing would burn the whole remaining
  // sweep as permanentFailed, so this HALTS the sweep RESUMABLE (5A): the user re-auths /
  // fixes the token and resumes from the checkpoint, re-attempting the walled items.
  return status === 401 || status === 403;
}
function isPermanentHttp(status) {
  // A hard client error the CDN/app won't recover from — except 429 (throttling) and the
  // auth-wall codes (handled above as a resumable halt, not a per-item permanent fail).
  return typeof status === "number" && status >= 400 && status < 500 && status !== 429;
}
function isRetryableHttp(status) {
  return typeof status === "number" && (status === 429 || (status >= 500 && status < 600));
}

/**
 * Map an `ingestOne` result ([C5]) to a bulk `{ outcome, signal }` ([C7]). This is
 * the DEFAULT relay-outcome mapper the production relay wraps around `ingestOne`
 * (composed in the Phase-6 wiring); the engine itself only ever sees `{ outcome,
 * signal }`, so it stays platform- and transport-blind.
 *
 * Classification keys off `result.status` (robust) and REFINES with
 * `result.httpStatus` when a caller supplies it (forward-compatible — absent
 * today, so the safe status-based defaults apply and sharpen for free later):
 *   saved            → ingested / deduped
 *   unreachable      → retryableFailed + HALT (the local app is down → pause the
 *                      whole sweep; the user resumes when it's back)
 *   fetch-error      → retryableFailed (transient CDN hiccup / throttle). A hard
 *                      4xx (media gone) is permanent only when httpStatus says so;
 *                      otherwise it exhausts the retry budget and is recorded
 *                      retryableFailed — bounded, never lost, never a false halt.
 *                      A 401/403 is an AUTH WALL → HALT resumable (5A), not a per-item
 *                      fail — the session is unauthorized, so the rest would all fail.
 *   ingest-error     → permanentFailed (our own loopback app rejected it:
 *                      unsupported type / bad request). A 5xx is transient; a 401/403
 *                      (bad/expired token) is an auth wall → HALT resumable.
 *   blocked-host     → (default arm) permanentFailed — a 3A SSRF refusal, never fetched.
 */
export function classifyIngestResult(result) {
  switch (result && result.status) {
    case "saved": {
      // The item ingested — but if the app reports the job paused/cancelled (7A
      // relay feedback), record it and then HALT the sweep after this item. Surface
      // WHICH status the app set (paused vs halted/cancel) so the caller can close the
      // ledger correctly: a Pause must stay resumable, an explicit Cancel terminal.
      const app =
        result.jobStatus === "paused" || result.jobStatus === "halted"
          ? result.jobStatus : null;
      return {
        outcome: result.deduplicated ? OUTCOMES.deduped : OUTCOMES.ingested,
        signal: app ? "halt" : "continue",
        appStatus: app,
      };
    }
    case "unreachable":
      return { outcome: OUTCOMES.retryableFailed, signal: "halt" };
    case "fetch-error":
      // An auth wall (401/403) from the media CDN halts the whole sweep resumable — a
      // per-item permanent fail would silently discard the rest of the board (5A).
      if (isAuthWall(result.httpStatus)) return { outcome: OUTCOMES.retryableFailed, signal: "halt" };
      return isPermanentHttp(result.httpStatus)
        ? { outcome: OUTCOMES.permanentFailed, signal: "continue" }
        : { outcome: OUTCOMES.retryableFailed, signal: "continue" };
    case "ingest-error":
      // A 401/403 from our own app (a bad/expired token) is likewise session-wide → halt
      // resumable so the user fixes the token and continues, not lose the remaining items.
      if (isAuthWall(result.httpStatus)) return { outcome: OUTCOMES.retryableFailed, signal: "halt" };
      return isRetryableHttp(result.httpStatus)
        ? { outcome: OUTCOMES.retryableFailed, signal: "continue" }
        : { outcome: OUTCOMES.permanentFailed, signal: "continue" };
    default:
      // no-image / no-token never reach the bulk relay (every BulkItem carries
      // media; the token is checked once at sweep start). Record defensively.
      return { outcome: OUTCOMES.permanentFailed, signal: "continue" };
  }
}

const zeroCounts = () => ({
  ingested: 0, deduped: 0, skipped: 0, retryableFailed: 0, permanentFailed: 0,
});

/**
 * Run a bulk sweep to completion (or to a `halt`). Returns
 * `{ status: "complete" | "halted", cursor, counts }` where `cursor` is the last
 * safely-checkpointed resume token and `counts` tallies each outcome.
 *
 * @param driver   `{ enumerate(input, { cursor }): AsyncIterable<BulkItem> }`.
 * @param input    opaque driver input (board id / "bookmarks" / …).
 * @param opts.relay      `async (item, { attempt }) => { outcome, signal? }` — the
 *                        per-item relay (production: `ingestOne` + `classifyIngestResult`).
 * @param opts.knownSet   a `Set` of already-ingested sourceIds ([P14]); items in it
 *                        are `skipped` with NO relay. Grown as the sweep ingests, so
 *                        a duplicate later in the SAME sweep is skipped too.
 * @param opts.storage    `{ load(key), save(key, value) }` for resume checkpoints
 *                        (production: `chrome.storage.local`). Optional.
 * @param opts.checkpointKey  storage key for this job's checkpoint. Optional.
 * @param opts.config     per-run overrides of the config.js knobs.
 * @param opts.onProgress `(counts) => void` after each terminal item (for the UI).
 * @param opts.sleep      `(ms) => Promise` — injected so tests use no real timers.
 * @param opts.random     `() => [0,1)` — injected so jitter is deterministic in tests.
 * @param opts.log        diagnostic sink.
 */
export async function runSweep(driver, input, {
  relay,
  knownSet = new Set(),
  storage = null,
  checkpointKey = null,
  config = {},
  onProgress = null,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  random = Math.random,
  log = () => {},
} = {}) {
  if (typeof relay !== "function") throw new Error("runSweep requires a relay function");

  const cfg = {
    MAX_CONCURRENCY, PACING_MS, PACING_JITTER_MS,
    BACKOFF_BASE_MS, BACKOFF_MAX_MS, MAX_ITEM_RETRIES,
    ...config,
  };

  // Resume: a prior checkpoint's cursor seeds enumeration; the app's dedup + the
  // known-set make any re-processed overlap idempotent, so an approximate resume
  // point is safe — it never double-ingests, only re-skips.
  let startCursor = null;
  if (storage && checkpointKey) {
    const saved = await storage.load(checkpointKey);
    if (saved && saved.cursor != null) startCursor = saved.cursor;
  }

  const counts = zeroCounts();
  const completed = new Map();   // seq → cursor, pending contiguous commit
  let committedSeq = -1;         // highest seq whose whole prefix is terminal
  let committedCursor = startCursor;
  let lastSavedSeq = -1;
  let halting = false;
  let appHaltStatus = null;      // "paused" | "halted" if the app (7A) halted us
  let nextSeq = 0;
  let iterDone = false;
  let enumerationError = null;

  const iterator = driver.enumerate(input, { cursor: startCursor })[Symbol.asyncIterator]();

  // Serialize `iterator.next()` across the concurrent workers (async iterators are
  // not re-entrant) and stamp each pulled item with a monotonic seq for ordering.
  let pullChain = Promise.resolve();
  function pull() {
    pullChain = pullChain.then(async () => {
      if (iterDone || halting) return null;
      try {
        const { value, done } = await iterator.next();
        if (done) { iterDone = true; return null; }
        return { item: value, seq: nextSeq++ };
      } catch (error) {
        // The driver failed to enumerate (a fatal page fetch / auth wall). Don't
        // crash the sweep — halt gracefully so the checkpoint is preserved and the
        // user can resume. The driver owns retrying transient page fetches; an
        // error reaching here means it gave up.
        log("driver enumeration failed → halting sweep:", String(error));
        enumerationError = error;
        halting = true;
        iterDone = true;
        return null;
      }
    });
    return pullChain;
  }

  async function pace() {
    await sleep(cfg.PACING_MS + Math.floor(random() * cfg.PACING_JITTER_MS));
  }

  // Advance the checkpoint over the CONTIGUOUS completed prefix only. With
  // concurrency, item N+1 can finish before item N; committing N+1's cursor then
  // would strand N on a resume. So we only move the watermark forward while the
  // next seq is present, and persist the cursor of that safe prefix.
  async function checkpoint() {
    let advanced = false;
    while (completed.has(committedSeq + 1)) {
      committedSeq += 1;
      committedCursor = completed.get(committedSeq);
      completed.delete(committedSeq);
      advanced = true;
    }
    if (advanced && storage && checkpointKey && committedSeq > lastSavedSeq) {
      try {
        await storage.save(checkpointKey, { cursor: committedCursor, counts: { ...counts } });
        lastSavedSeq = committedSeq; // mark saved ONLY on success
      } catch (error) {
        // A checkpoint write failure must NOT abort the sweep (8A) — it's a resume
        // optimisation, not correctness. Log and continue; because lastSavedSeq is left
        // un-advanced, the NEXT checkpoint retries the save with a fresher cursor, and a
        // resume from the last successfully-saved cursor only re-skips via dedup.
        log("checkpoint save failed (non-fatal — resume re-skips via dedup):", String(error));
      }
    }
  }

  async function record(outcome, seq, cursor) {
    counts[outcome] += 1;
    completed.set(seq, cursor);
    if (onProgress) onProgress({ ...counts });
    await checkpoint();
  }

  async function processItem(item, seq) {
    if (knownSet.has(item.sourceId)) {           // [P14] skip — no pace, no relay
      await record(OUTCOMES.skipped, seq, item.cursor);
      return;
    }

    let attempt = 0;
    while (true) {
      if (halting) return;                       // sweep is winding down — abandon
                                                 // this item un-recorded; the
                                                 // watermark holds below it, so a
                                                 // resume re-enumerates it.
      await pace();

      let outcome, signal, appStatus;
      try {
        ({ outcome, signal = "continue", appStatus = null } = await relay(item, { attempt }));
      } catch (error) {
        // A relay that THROWS (rather than returning an outcome) is treated as a
        // transient fault — requeue with backoff like any retryableFailed.
        log("relay threw; treating as retryable:", String(error));
        outcome = OUTCOMES.retryableFailed;
        signal = "continue";
      }

      const canRetry =
        outcome === OUTCOMES.retryableFailed && signal !== "halt" && attempt < cfg.MAX_ITEM_RETRIES;
      if (canRetry) {
        attempt += 1;
        await sleep(computeBackoff(attempt, cfg));   // [P13] adaptive backoff
        continue;
      }

      if (outcome === OUTCOMES.ingested || outcome === OUTCOMES.deduped) {
        knownSet.add(item.sourceId);               // dedup a repeat later this sweep
      }
      await record(outcome, seq, item.cursor);
      if (signal === "halt") {                      // [C7] fatal wall / [7A] app halt
        halting = true;
        if (appStatus) appHaltStatus = appStatus;   // remember Pause vs Cancel intent
      }
      return;
    }
  }

  async function worker() {
    while (!halting) {
      const pulled = await pull();
      if (!pulled) return;                         // iterator drained (or halting)
      await processItem(pulled.item, pulled.seq);
    }
  }

  const workerCount = Math.max(1, cfg.MAX_CONCURRENCY);
  await Promise.all(Array.from({ length: workerCount }, () => worker()));

  await checkpoint();  // final flush for any tail that completed out of order

  return {
    status: halting ? "halted" : "complete",
    // Why it halted, so the caller closes the ledger correctly: "halted" (app Cancel)
    // is terminal; "paused" (app Pause) and null (a wall/unreachable self-halt) are
    // both resumable. Only meaningful when status === "halted".
    haltStatus: appHaltStatus,
    cursor: committedCursor,
    counts: { ...counts },
    error: enumerationError ? String(enumerationError) : null,
  };
}

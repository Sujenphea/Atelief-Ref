// Atelier Capture — the content-script bulk controller (Phase 6, [1A]).
//
// Runs in the page (durable while the tab is open, so it survives the SW being torn
// down mid-sweep — the MV3 [A1] requirement). It owns the sweep: open a job, load the
// known-source skip set, drive the engine over the platform driver, relay each item
// to the SW, checkpoint to `storage.local`, close the job. All localhost I/O is
// proxied to the SW via an injected `transport` (`runtime.sendMessage`), so the
// orchestration CORE (`runBulkSweep`) is pure and unit-tested with a fake transport.
//
// The browser-API/window bootstrap (build the platform driver from the live page, wire
// the X hook's messages, checkpoint store) is thin guarded glue at the tail —
// exercised by manual E2E (Phase 9), not node --test. `registerBulkController` takes
// the API as an ARGUMENT, so the bootstrap-tests drive it with a fake and the live
// call at the foot hands it the `browser.js` shim.

import { runSweep, classifyIngestResult } from "./bulk-engine.js";
import { PLATFORM_PACING } from "./config.js";
import {
  BULK, START, TIMELINE_MESSAGE_SOURCE, TIMELINE_REPLAY_SOURCE,
  REDNOTE_FEED_MESSAGE_SOURCE, REDNOTE_REPLAY_SOURCE, readStartMessage,
} from "./bulk-messages.js";
import {
  pinterestBoardDriver, makeResourceFetch, scrapePinterestAppVersionFromDoc, readCookie,
} from "./bulk-pinterest.js";
import { createTwitterSource } from "./twitter-source.js";
import { createThreadExpander, featuresFromURL, resolveQueryId } from "./twitter-detail-client.js";
import { createHookProxyFetch } from "./hook-proxy.js";
import { makeSavedFeedFetch, instagramSavedDriver } from "./bulk-instagram.js";
import { createRednoteSource } from "./rednote-source.js";
import { isNoteDetailRequest } from "./bulk-rednote.js";
import {
  createNoteExpander, createPageNoteDriver, isRednoteChallenge,
} from "./rednote-detail-client.js";
import { readVideoCandidates } from "./rednote-video.js";
import { browser } from "./browser.js";

/**
 * Orchestrate one sweep to completion (or a halt). Pure/injectable: `transport`
 * proxies every localhost op to the SW, `driver` is the platform BulkSource, and the
 * engine collaborators (`storage`/`sleep`/`random`) pass straight through.
 *
 * @param spec.platform      "pinterest" | "twitter" (the job's platform).
 * @param spec.input         driver input (a board `{ boardId, boardUrl }` / X ignores it).
 * @param spec.resolveVideo  opt-in: relay the resolved MP4 instead of the poster. On
 *                           rednote it also decides whether a VIDEO note is worth opening
 *                           at all — the ladder exists only in a note-detail response, so
 *                           the two toggles compose: `expandNotes` alone opens notes and
 *                           takes their photos, both together also takes their streams, and
 *                           `resolveVideo` alone changes nothing (a cover-only sweep never
 *                           fetches a note detail, so no ladder is ever seen).
 * @param spec.expandNotes   opt-in (rednote): open each note for the rest of its images.
 * @param opts.expansion     the note-open expander when `expandNotes` is on, else null.
 *                           `{ arm, stats }` — armed with the known-set once it is loaded
 *                           (the pre-check cannot exist before then), read back afterwards
 *                           so the sweep can report a PARTIAL expansion as a first-class
 *                           outcome (098 R7) rather than a silent shortfall.
 * @returns `{ jobId, caps, status, cursor, counts, expansion, error }`.
 */
export async function runBulkSweep(spec, {
  transport, driver, storage = null, config = {}, onProgress = null, sleep, random, log = () => {},
  earlyStopThreshold = null, expansion = null,
}) {
  const { platform, input, scope = null, totalEstimate = null, resolveVideo = false } = spec;

  // Checkpoint under a STABLE per-target key (the board / bookmarks-set), NOT the
  // jobId — every run opens a fresh job, so a jobId-scoped key would strand the
  // saved cursor and force a full re-enumeration on resume. Keyed this way, a
  // killed run's cursor is exactly what the next run reads back.
  const checkpointKey = sweepCheckpointKey({ platform, scope, input });

  // Task 8 — RESUME THE SAME JOB. A resumable halt leaves the prior run's jobId in the
  // checkpoint; hand it to the app so it reopens THAT job instead of minting a new one
  // (one logical sweep → one ledger row). The app falls back to a fresh job if it's no
  // longer resumable, so a stale id is safe.
  const prior = storage && storage.load ? await storage.load(checkpointKey) : null;
  const resumeJobId = prior && prior.jobId ? prior.jobId : null;

  // Re-sweep early-stop (14A): arm it ONLY on a fresh sweep (no outstanding checkpoint)
  // whose PRIOR run of this scope closed clean — failure-free. The clean marker persists
  // separately from the checkpoint (which a clean close clears), so it survives to gate the
  // next run. This keeps a stranded retryable/permanent item from being walled off behind
  // the known-run: any prior failure forces a full re-walk that re-attempts it. Fully
  // extension-side — no app/server change. Threshold is IG-only (config), null elsewhere.
  const cleanMarkerKey = sweepCleanMarkerKey({ platform, scope, input });
  const freshStart = !prior;
  const engineConfig = { ...config };
  // Read once, used by two optimisations with the same precondition (a FRESH sweep whose
  // prior run of this scope closed clean): Instagram's early-stop, and rednote's
  // note-level pre-check. Only read when one of them could be armed, so the storage call
  // is not made on every sweep for nothing.
  const lastClean = freshStart && storage && storage.load && (earlyStopThreshold || expansion)
    ? await storage.load(cleanMarkerKey) : null;
  const priorClean = !!lastClean && lastClean.clean === true;
  if (earlyStopThreshold && priorClean) {
    engineConfig.STOP_AFTER_CONSECUTIVE_SKIPS = earlyStopThreshold;
    log("re-sweep early-stop armed (prior sweep clean), threshold", earlyStopThreshold);
  }

  const { jobId, caps } = await transport({
    type: BULK.open, platform, scope, totalEstimate, resumeJobId,
  });
  const knownSet = new Set(await transport({ type: BULK.known, jobId }));

  // 098 R14 + the mode trap. The note-level pre-check stops a re-sweep re-opening ~400
  // notes to ingest nothing, and it is armed only when the prior sweep of this scope closed
  // clean AND was at least as RICH as this one — `sweepMode` records which pass ran, because
  // a cover-only sweep leaves every note's `<note_id>` known and would otherwise skip every
  // note-open of the first expansion sweep. See `armsNotePreCheck`.
  if (expansion) {
    const armed = priorClean && armsNotePreCheck(lastClean, sweepMode(spec));
    expansion.arm({ knownSet, armed });
    if (!armed) {
      log("note-level pre-check disarmed — prior sweep was",
        lastClean ? `${lastClean.mode || "an older build"} / clean=${lastClean.clean}` : "absent");
    }
  }

  // Stamp the (possibly reopened) jobId into every checkpoint the engine writes, so a
  // later resume can reopen this same job. The engine stays jobId-agnostic — it just
  // persists { cursor, counts } and this wrapper folds in the id.
  const checkpointStorage = storage ? {
    load: (key) => storage.load(key),
    save: (key, value) => storage.save(key, { ...value, jobId }),
    remove: (key) => storage.remove(key),
  } : storage;

  // Relay each item to the SW (only it can reach localhost); classify its result
  // into the engine's outcome taxonomy. Video is opt-in — the resolved MP4 lives in
  // the mapped provenance, so no extra network call is needed to find it.
  const relay = async (item) => {
    const result = await transport({
      type: BULK.relay,
      jobId,
      sourceId: item.sourceId,
      provenance: item.provenance,
      // A tweet content descriptor (003 · C3 bulk) so the item ingests as a first-class
      // tweet; null for image-only drivers (Pinterest) → the plain image path.
      content: item.content || null,
      mp4Url: resolveVideo ? (item.provenance?.rawMetadata?.videoUrl || null) : null,
      // THE STREAM LADDER, and the one place it is allowed to travel (098 D5 / 020 B3).
      //
      // `provenance` is persisted — it ships to the app and a checkpointed item would carry
      // it — and a stored `master_url` comes back 404 or points at a rung that is no longer
      // right, because the same note served a DIFFERENT ladder on two visits minutes apart.
      // So the ladder never enters provenance. It rides on the item as a NON-ENUMERABLE
      // property (`withVideoCandidates`), which every copy a checkpoint or a clone could
      // make silently drops, and `readVideoCandidates` is the single reader that asks for it
      // by name. From here it is a field on ONE runtime message, resolved seconds ago from
      // the response it arrived on, and nothing downstream stores it.
      //
      // Gated on the same `resolveVideo` toggle as `mp4Url`, because it means the same
      // thing: relay the resolved video rather than the still.
      videoCandidates: resolveVideo ? readVideoCandidates(item) : null,
      // Thread the server's authoritative byte caps (from job open, 13A) so the SW can
      // reject an over-cap image/video from its declared size BEFORE downloading it,
      // instead of streaming a doomed file only for the app to 413 it.
      caps,
    });
    // Quiet on the happy path; surface only a non-"saved" result (blocked-host,
    // fetch-error, unreachable, …) so a broken sweep explains itself without spamming a
    // line per item on a healthy one.
    if (!result || result.status !== "saved") {
      log("relay", item.sourceId, "->", (result && result.status) || "no-result",
        result && result.httpStatus != null ? "http" + result.httpStatus : "");
    }
    return classifyIngestResult(result);
  };

  const result = await runSweep(driver, input, {
    relay, knownSet, storage: checkpointStorage, checkpointKey,
    config: engineConfig, onProgress, sleep, random, log,
  });

  // Map the engine's terminal state to the ledger close status (7A). A clean finish
  // completes. A halt is RESUMABLE (→ paused) — a user Pause or a wall/unreachable
  // self-halt — UNLESS the app explicitly Cancelled the job (haltStatus "halted"),
  // which stays terminal. (The old code always sent "halted", clobbering a Pause into
  // a non-resumable "Stopped" job; the server's /complete accepts "paused" for exactly
  // this.)
  const cancelled = result.haltStatus === "halted";
  const closeStatus =
    result.status !== "halted" ? "complete" : (cancelled ? "halted" : "paused");
  await transport({ type: BULK.complete, jobId, status: closeStatus });

  // Clear the checkpoint on a TERMINAL close — a clean finish or an explicit Cancel —
  // so a later re-sweep starts fresh (page 1, picking up items added since). Keep it
  // only for a RESUMABLE halt (Pause / wall) so the next run continues from the cursor.
  // The sweep already completed on the server by here; a local checkpoint-cleanup
  // failure is cosmetic (a resume just re-skips via dedup), so it must LOG, never
  // reject and mask an otherwise-successful sweep (12A). A stale checkpoint is at worst
  // a redundant re-enumeration next run, which the known-set makes idempotent.
  const resumable = result.status === "halted" && !cancelled;
  if (!resumable && storage && storage.remove) {
    try {
      await storage.remove(checkpointKey);
    } catch (error) {
      log("checkpoint cleanup failed (non-fatal — a resume re-skips via dedup):", String(error));
    }
  }

  // Record whether this CLEAN completion was failure-free, so the NEXT fresh sweep of this
  // scope may early-stop (14A). A run with any retryable/permanent fail records `clean:false`,
  // forcing the next sweep to full-walk and re-attempt the stray. Persisted separately from
  // the (now-cleared) checkpoint. Best-effort — a write failure only forgoes a future
  // optimisation, so it LOGs rather than failing an otherwise-successful sweep.
  const expansionStats = expansion ? expansion.stats() : null;
  if (result.status === "complete" && storage && storage.save) {
    try {
      const clean = result.counts.retryableFailed === 0 && result.counts.permanentFailed === 0;
      // The MODE rides beside `clean` (098 R14's mode trap). Without it a marker says only
      // "the last sweep of this board was failure-free" — which is true of a cover-only
      // sweep and of an expansion sweep alike, and arming an expansion sweep's note-level
      // pre-check off the former skips every note-open there is. A marker from an older
      // build has no `mode` at all; that reads as UNKNOWN and arms nothing, while leaving
      // the `clean` rule Instagram's early-stop uses exactly as it was.
      await storage.save(cleanMarkerKey, { clean, mode: sweepMode(spec) });
    } catch (error) {
      log("clean-marker write failed (non-fatal — next sweep just full-walks):", String(error));
    }
  }

  // A sweep where some notes expanded and some kept their cover is NOT the same sweep as
  // one where all of them expanded, and before this it reported identically (098 R7). The
  // stats ride out on the result so the popup, the log line and any caller can tell them
  // apart — `expansion.partial` is the one field that answers it.
  return { jobId, caps, ...result, expansion: expansionStats };
}

/** Which PASS this sweep runs: the baseline every platform has, or rednote's note-open
 * expansion (098 D4). Recorded in the clean marker, and compared against the marker's on
 * the next sweep. */
export function sweepMode(spec) {
  return spec && spec.expandNotes ? "expansion" : "cover";
}

/** How rich each recorded pass is. Ordered, because the question the pre-check asks is not
 * "was the prior sweep the same?" but "did the prior sweep capture at least what this one
 * is about to?". */
const MODE_RANK = Object.freeze({ cover: 0, expansion: 1 });

/**
 * May this sweep trust the prior clean sweep's coverage enough to pre-check the known-set
 * per NOTE (098 R14), given the marker it left?
 *
 *   prior expansion → this expansion : YES — the R14 case, the whole point.
 *   prior cover     → this expansion : no  — every note still owes its images.
 *   prior expansion → this cover     : no  — a cover was never keyed `<note_id>:<index>`
 *                                            (the cover pass has no note-open to skip
 *                                            anyway, so this arm is belt and braces).
 *   no recorded mode                 : no  — a marker written by a build that predates
 *                                            this field. UNKNOWN is not "cover" and is not
 *                                            "expansion"; it arms nothing, and every rule
 *                                            that existed before it keeps working.
 *
 * `clean` is the caller's to check — this answers only the coverage half.
 */
export function armsNotePreCheck(marker, mode) {
  const prior = marker ? MODE_RANK[marker.mode] : undefined;
  if (prior === undefined) return false;
  return prior >= MODE_RANK[mode];
}

/** A stable per-target checkpoint key: the same board / bookmarks-set resumes across
 * runs. Prefers the concrete board id, falls back to the scope, then the platform. */
export function sweepCheckpointKey({ platform, scope = null, input = null }) {
  const target = (input && input.boardId) || scope || "default";
  return `atelier:bulk:${platform}:${target}`;
}

/** The persistent "was the last completed sweep of this target failure-free?" marker key
 * (14A). Derived from the checkpoint key + a suffix so it points at the SAME target but
 * survives the checkpoint's clean-close clearing — it's what arms the next sweep's
 * early-stop. */
export function sweepCleanMarkerKey({ platform, scope = null, input = null }) {
  return `${sweepCheckpointKey({ platform, scope, input })}:lastclean`;
}

// ---------------------------------------------------------------------------
// Content-script bootstrap (browser-API/window glue — guarded; E2E-verified)
// ---------------------------------------------------------------------------

/** A `transport` backed by `runtime.sendMessage`, surfacing an error reply
 * (see the SW glue in sw.js) as a thrown error the controller can halt on. */
export function makeRuntimeTransport(sendMessage) {
  return async (message) => {
    const reply = await sendMessage(message);
    if (reply && reply.__error) throw new Error(reply.__error);
    return reply;
  };
}

/** A `{ load, save, remove }` checkpoint store over an extension `storage.local`. */
export function makeChromeStorage(area) {
  return {
    async load(key) { return (await area.get(key))[key] ?? null; },
    async save(key, value) { await area.set({ [key]: value }); },
    async remove(key) { await area.remove(key); },
  };
}

/** Build the Pinterest board driver from the live page: same-origin credentialled
 * `/resource/` fetch, app-version scraped from the bootstrap, csrftoken from cookie.
 * Returns `{ driver, dispose }` — Pinterest holds no page listener, so `dispose` is a
 * no-op (the shape matches buildTwitterDriver so the caller tears down uniformly). */
function buildPinterestDriver({ doc, loc, fetchImpl }) {
  const appVersion = scrapePinterestAppVersionFromDoc(doc);
  const csrfToken = readCookie(doc.cookie, "csrftoken");
  const fetchJson = makeResourceFetch({ appVersion, csrfToken, fetchImpl });
  return { driver: pinterestBoardDriver({ fetchJson, host: loc.host }), dispose: () => {} };
}

/** Build the X driver: subscribe to the MAIN-world hook's timeline messages and feed
 * them to the push→pull source, which auto-scrolls to page. Returns `{ driver, dispose }`
 * — `dispose` REMOVES the `message` listener (1A): without it every launch leaks another
 * live listener feeding a now-dead source, and a stale one could push pages into the
 * wrong sweep. The caller runs `dispose` when the sweep settles. */
function buildTwitterDriver({ win, host, scope, transport, log = () => {} }) {
  // What the follow-up TweetDetail call needs, harvested from the page's OWN timeline
  // requests as they stream past: the `features` blob off the request URL, and the fact
  // (`hasAuth`) that the MAIN-world hook has the matching auth headers. The header VALUES
  // are deliberately not here and never will be — they stay in the hook's closure and
  // only it replays them, so nothing that authorizes a request ever crosses the page's
  // shared `postMessage` bus ([090] 3A).
  let harvested = null;

  // Two unrelated things can leave expansion without credentials, and they point
  // somewhere completely different: no harvest means the MAIN-world hook never handed us
  // an auth-bearing timeline response (none seen yet — or, as happened live, a STALE hook
  // build whose envelope predates `hasAuth` and so can never set it); no queryId means
  // X moved the operation table. Collapsing both into `null` is what let a stale hook
  // read as "the bundle moved" and sent the search to the one place that was fine, so
  // the unavailable case names ITSELF via `reason` rather than leaving the caller to guess.
  const resolveCredentials = async () => {
    if (!harvested) {
      return {
        reason: "the hook has not handed over X's auth headers — no timeline response seen "
          + "yet, or the MAIN-world hook is an older build (reload the extension)",
      };
    }
    const queryId = await resolveQueryId({
      doc: win.document,
      // The SW fetches the bundle: a content script's cross-origin fetch is bound by
      // the page's CORS, the SW's by host_permissions.
      fetchBundle: async (url) => {
        const reply = await transport({ type: BULK.bundle, url });
        return reply && reply.text ? reply.text : null;
      },
      log,
    });
    if (!queryId) {
      return { reason: "no TweetDetail queryId in any X bundle (the operation table moved?)" };
    }
    return { queryId, features: harvested.features };
  };

  // The TweetDetail call goes through the hook's proxy, so it carries the tab's session
  // without the sweep ever holding the token. Absent on a bare test window (no
  // `addEventListener`) — expansion is simply off then, the same graceful path a missing
  // queryId takes.
  const proxy = typeof win.addEventListener === "function" ? createHookProxyFetch({ win }) : null;

  const source = createTwitterSource({
    host,
    scope,
    scroll: () => win.scrollTo(0, win.document.body.scrollHeight),
    // `probeRoots` is on with no toggle: a bookmarked tweet that STARTS a thread is
    // indistinguishable from a lone tweet in the timeline, so the only way "save the
    // whole thread" holds for the common case (bookmarking the first tweet) is to ask.
    // The cost is one TweetDetail per bookmarked tweet that has any replies; tweets
    // with none are screened out for free, and each conversation is fetched once.
    expandItems: proxy
      ? createThreadExpander({
        resolveCredentials, probeRoots: true, host, fetchImpl: proxy.proxyFetch, log,
      })
      : null,
  });
  const onMessage = (event) => {
    if (event.source === win && event.data && event.data.source === TIMELINE_MESSAGE_SOURCE) {
      const features = featuresFromURL(event.data.url);
      // Both halves must be present: the features blob to build the request with, and the
      // hook's word that it holds the credentials to send it with.
      if (features && event.data.hasAuth) harvested = { features };
      source.onResponse(event.data.json, event.data.url);
    }
  };
  win.addEventListener("message", onMessage);
  // Replay the pages X already fetched BEFORE this listener existed — above all the
  // FIRST page, loaded on navigation. Without it a short timeline (a small bookmark
  // folder whose items fit on page 1, or an already-scrolled one) captures nothing: the
  // auto-scroll only triggers the empty tail page. The MAIN-world hook (installed at
  // document_start) buffers recent responses and re-posts them on this request; dedup
  // makes any overlap with the live pages idempotent.
  win.postMessage({ source: TIMELINE_REPLAY_SOURCE }, win.location.origin);
  return {
    driver: source,
    dispose: () => {
      win.removeEventListener("message", onMessage);
      if (proxy) proxy.dispose();              // and reject anything still in flight
    },
  };
}

/** Build the Instagram driver (002 · O2): a same-origin credentialled `fetch` to the
 * saved-feed REST endpoint, paginated by `next_max_id`. The mirror image of
 * buildPinterestDriver — a PULL driver, NOT a hook source: IG's saved feed can't be
 * intercepted (the request bypasses the page's fetch/XHR) and its infinite scroll needs a
 * trusted wheel, so we replay the endpoint ourselves. The session cookie authorizes it
 * (`credentials:'include'`); the only header is the public `x-ig-app-id` constant, so —
 * like Pinterest — `dispose` is a no-op (no page listener held). */
function buildInstagramDriver({ loc, fetchImpl, log = () => {} }) {
  const fetchJson = makeSavedFeedFetch({ fetchImpl, log });
  return { driver: instagramSavedDriver({ fetchJson, host: loc.host }), dispose: () => {} };
}

/** Build the rednote board driver (098 T3/T5b): subscribe to the MAIN-world hook's
 * messages and feed them to the push→pull source, which scrolls to page. Shaped like
 * buildTwitterDriver — and deliberately smaller. There is no credential to harvest and no
 * proxy to wire, because rednote's `X-s` is signed for the url it was issued for and
 * cannot be replayed onto a follow-up (098 D1). `dispose` REMOVES the listener: without it
 * every launch leaks another live listener feeding a dead source.
 *
 * ONE hook stream, TWO destinations. The hook forwards the board feed and — when the note
 * detail is being read — each note's own `POST /v1/feed`, on the same envelope tag. They
 * are told apart here by URL: the board pages go to the source, a detail body goes to the
 * expander's waiter. Routing on the url rather than on the payload is what stops a detail
 * response being fed to `parseBoardFeedPage`, whose challenge detector would read a body
 * with no `data.notes` as a REFUSAL and halt the sweep.
 *
 * Expansion is OFF unless the user asked for it (098 R13): with `expandNotes` false this
 * function is exactly the cover-pass driver it was, no expander, no note-opens, no budget.
 */
function buildRednoteDriver({
  win, host, scope, log = () => {}, expandNotes = false, resolveVideo = false, noteOpen = {},
}) {
  const expansion = expandNotes
    ? createNoteExpander({
      host,
      log,
      // The video toggle composes with the expansion toggle rather than duplicating it
      // (098 T6c): expansion decides whether notes are OPENED at all, `resolveVideo`
      // decides whether a video note has anything worth opening it for. Off, a video note
      // is refused unopened exactly as it was in T5b; on, it is opened for its stream.
      resolveVideo,
      budget: noteOpen.BUDGET,
      pacingMs: noteOpen.PACING_MS,
      pacingJitterMs: noteOpen.PACING_JITTER_MS,
      timeoutMs: noteOpen.TIMEOUT_MS,
      pollMs: noteOpen.POLL_MS,
      ...createPageNoteDriver({ win, settleMs: noteOpen.SETTLE_MS, log }),
    })
    : null;

  const source = createRednoteSource({
    host,
    scope,
    scroll: () => win.scrollTo(0, win.document.body.scrollHeight),
    onExpandFailure: (error) => log("note expansion degraded to the cover:", String(error)),
    expandItems: expansion ? expansion.expandItems : null,
    // A note-detail REFUSAL is not a degradation (098 D8): it is the same risk-control
    // answer the board feed can give, and degrading past one keeps opening notes against a
    // session rednote has already flagged. The seam re-raises it and the engine halts
    // resumable.
    isFatalExpandFailure: expansion ? isRednoteChallenge : null,
  });
  const onMessage = (event) => {
    if (event.source === win && event.data && event.data.source === REDNOTE_FEED_MESSAGE_SOURCE) {
      if (expansion && isNoteDetailRequest(event.data.url)) {
        expansion.onDetail(event.data.json, event.data.url);
      } else {
        source.onResponse(event.data.json, event.data.url);
      }
    }
  };
  win.addEventListener("message", onMessage);
  // Replay what the page fetched BEFORE this listener existed — above all the first page,
  // loaded on navigation. Without it a board whose notes all fit on page 1 captures
  // nothing: the scroll only triggers the empty tail.
  win.postMessage({ source: REDNOTE_REPLAY_SOURCE }, win.location.origin);
  return {
    driver: source,
    dispose: () => win.removeEventListener("message", onMessage),
    expansion,
  };
}

/**
 * Which builder serves which platform (098 R6). A MAP, not an if/else chain, for one
 * reason worth stating: the chain ended in a bare `else` that fell through to Pinterest,
 * so correctness depended on `SUPPORTED_PLATFORMS` and the chain agreeing — and a platform
 * added to the guard but not the chain would silently run the PINTEREST driver, which is
 * the exact failure the guard was written to prevent. Deriving the guard from these keys
 * makes the two impossible to disagree, and removes the default branch entirely.
 *
 * Each builder takes the whole context and destructures what it needs; they genuinely
 * need different things (a document, a location, a window, a transport), and forcing them
 * into one signature would be a worse trade than one shared bag.
 */
const DRIVER_BUILDERS = Object.freeze({
  twitter: ({ win, host, scope, transport, log }) =>
    buildTwitterDriver({ win, host, scope, transport, log }),
  instagram: ({ win, log }) =>
    buildInstagramDriver({ loc: win.location, fetchImpl: win.fetch.bind(win), log }),
  pinterest: ({ win }) =>
    buildPinterestDriver({ doc: win.document, loc: win.location, fetchImpl: win.fetch.bind(win) }),
  rednote: ({ win, host, scope, log, spec, pacing }) => buildRednoteDriver({
    win, host, scope, log,
    expandNotes: !!(spec && spec.expandNotes),
    resolveVideo: !!(spec && spec.resolveVideo),
    noteOpen: (pacing && pacing.noteOpen) || {},
  }),
});

/** Platforms the controller can build a driver for — DERIVED from the builder map, so a
 * platform can never be accepted without something to dispatch it to. Exported so
 * `platform-registry.test.js` can hold every other registration point against it. */
export const SUPPORTED_PLATFORMS = new Set(Object.keys(DRIVER_BUILDERS));

/** Register the START-message listener on a page. Extracted so the guard + wiring are
 * one place; idempotent via a window flag so a re-injection (the cold-tab recovery in
 * bulk-dispatch.js) can't leave two listeners → two sweeps for one click. */
export function registerBulkController(win, browserApi) {
  if (win.__atelierBulkController) return; // already wired on this page
  win.__atelierBulkController = true;

  browserApi.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!message || message.type !== START) return false;

    // Per-tab guard (1A): one sweep at a time on a page. A second START — a double-click,
    // or the cold-tab re-injection racing the popup — is refused, not run concurrently:
    // two sweeps would double the request rate (a scraper tell) and, for X, two message
    // listeners would cross-feed each other's pages. The flag lives on `win`, so it's
    // per-tab and survives the SW being torn down mid-sweep.
    if (win.__atelierSweepInFlight) {
      sendResponse({ ok: false, error: "sweep-already-running" });
      return true;
    }

    const spec = readStartMessage(message);
    // Reject an unknown platform with a TYPED error (7A) instead of silently falling
    // through to the Pinterest driver — which, on an X page, would scrape the wrong
    // bootstrap and open a job that ingests nothing. Validated before the guard is set,
    // so a bad message never blocks a subsequent good one.
    if (!SUPPORTED_PLATFORMS.has(spec.platform)) {
      sendResponse({ ok: false, error: `unsupported-platform: ${spec.platform}` });
      return true;
    }
    win.__atelierSweepInFlight = true;

    // Diagnostic trace to the page console (visible in the tab's DevTools). Cheap + always
    // on: a bulk sweep is a rare, user-initiated action, and "why did my sweep do nothing"
    // is otherwise invisible. Every line is prefixed so it's easy to filter.
    const log = (...args) => { try { console.log("[Atelier bulk]", ...args); } catch { /* ignore */ } };
    log("START", spec.platform, spec.scope || "", "resolveVideo=" + !!spec.resolveVideo,
      "expandNotes=" + !!spec.expandNotes);

    const transport = makeRuntimeTransport((m) => browserApi.runtime.sendMessage(m));
    const storage = makeChromeStorage(browserApi.storage.local);
    const host = win.location.host;
    const pacing = PLATFORM_PACING[spec.platform] || {};
    const { driver, dispose, expansion = null } = DRIVER_BUILDERS[spec.platform](
      { win, host, scope: spec.scope, transport, log, spec, pacing });
    log("driver built for", spec.platform, "on", host);
    // Per-platform engine pacing (13A): IG sweeps gentler; X/Pinterest inherit the globals.
    // (No per-item progress log — the app's Sweeps tab owns live progress; the final
    // `sweep SETTLED` line below carries the totals.)
    const earlyStopThreshold = (pacing.reSweep && pacing.reSweep.STOP_AFTER_CONSECUTIVE_SKIPS) || null;
    runBulkSweep(spec, { transport, driver, expansion, storage, config: pacing.engine || {}, log, earlyStopThreshold })
      .then((result) => { log("sweep SETTLED", result.status, result.earlyStopped ? "(early-stop)" : "", JSON.stringify(result.counts), result.expansion ? "expansion " + JSON.stringify(result.expansion) : "", result.error || ""); sendResponse({ ok: true, result }); })
      .catch((error) => { log("sweep THREW", String(error)); sendResponse({ ok: false, error: String(error) }); })
      .finally(() => { win.__atelierSweepInFlight = false; dispose(); }); // release guard + tear down listener
    return true; // async sendResponse
  });
}

// Guarded so a `node --test` import (no browser global / no window) is inert. The real
// bootstrap is triggered by a START runtime message from the popup (or the injection
// recovery). The shim is passed whole — `registerBulkController` only ever reaches for
// `runtime` and `storage`, which is exactly what the fake in the bootstrap tests supplies.
if (browser.runtime && browser.storage && typeof window !== "undefined") {
  registerBulkController(window, browser);
}

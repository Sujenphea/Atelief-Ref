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
  BULK, START, TIMELINE_MESSAGE_SOURCE, TIMELINE_REPLAY_SOURCE, readStartMessage,
} from "./bulk-messages.js";
import {
  pinterestBoardDriver, makeResourceFetch, scrapePinterestAppVersionFromDoc, readCookie,
} from "./bulk-pinterest.js";
import { createTwitterSource } from "./twitter-source.js";
import { createThreadExpander, featuresFromURL, resolveQueryId } from "./twitter-detail-client.js";
import { createHookProxyFetch } from "./hook-proxy.js";
import { makeSavedFeedFetch, instagramSavedDriver } from "./bulk-instagram.js";
import { browser } from "./browser.js";

/** Platforms the controller can build a driver for. A START for anything else is refused
 * with a typed error rather than silently mis-dispatched. */
const SUPPORTED_PLATFORMS = new Set(["twitter", "pinterest", "instagram"]);

/**
 * Orchestrate one sweep to completion (or a halt). Pure/injectable: `transport`
 * proxies every localhost op to the SW, `driver` is the platform BulkSource, and the
 * engine collaborators (`storage`/`sleep`/`random`) pass straight through.
 *
 * @param spec.platform      "pinterest" | "twitter" (the job's platform).
 * @param spec.input         driver input (a board `{ boardId, boardUrl }` / X ignores it).
 * @param spec.resolveVideo  opt-in: relay the resolved MP4 instead of the poster.
 * @returns `{ jobId, caps, status, cursor, counts, error }`.
 */
export async function runBulkSweep(spec, {
  transport, driver, storage = null, config = {}, onProgress = null, sleep, random, log = () => {},
  earlyStopThreshold = null,
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
  if (earlyStopThreshold && freshStart && storage && storage.load) {
    const lastClean = await storage.load(cleanMarkerKey);
    if (lastClean && lastClean.clean === true) {
      engineConfig.STOP_AFTER_CONSECUTIVE_SKIPS = earlyStopThreshold;
      log("re-sweep early-stop armed (prior sweep clean), threshold", earlyStopThreshold);
    }
  }

  const { jobId, caps } = await transport({
    type: BULK.open, platform, scope, totalEstimate, resumeJobId,
  });
  const knownSet = new Set(await transport({ type: BULK.known, jobId }));

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
  if (result.status === "complete" && storage && storage.save) {
    try {
      const clean = result.counts.retryableFailed === 0 && result.counts.permanentFailed === 0;
      await storage.save(cleanMarkerKey, { clean });
    } catch (error) {
      log("clean-marker write failed (non-fatal — next sweep just full-walks):", String(error));
    }
  }

  return { jobId, caps, ...result };
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
    log("START", spec.platform, spec.scope || "", "resolveVideo=" + !!spec.resolveVideo);

    const transport = makeRuntimeTransport((m) => browserApi.runtime.sendMessage(m));
    const storage = makeChromeStorage(browserApi.storage.local);
    const host = win.location.host;
    const pacing = PLATFORM_PACING[spec.platform] || {};
    let built;
    if (spec.platform === "twitter") {
      built = buildTwitterDriver({ win, host, scope: spec.scope, transport, log });
    } else if (spec.platform === "instagram") {
      built = buildInstagramDriver({ loc: win.location, fetchImpl: win.fetch.bind(win), log });
    } else {
      built = buildPinterestDriver({ doc: win.document, loc: win.location, fetchImpl: win.fetch.bind(win) });
    }
    const { driver, dispose } = built;
    log("driver built for", spec.platform, "on", host);
    // Per-platform engine pacing (13A): IG sweeps gentler; X/Pinterest inherit the globals.
    // (No per-item progress log — the app's Sweeps tab owns live progress; the final
    // `sweep SETTLED` line below carries the totals.)
    const earlyStopThreshold = (pacing.reSweep && pacing.reSweep.STOP_AFTER_CONSECUTIVE_SKIPS) || null;
    runBulkSweep(spec, { transport, driver, storage, config: pacing.engine || {}, log, earlyStopThreshold })
      .then((result) => { log("sweep SETTLED", result.status, result.earlyStopped ? "(early-stop)" : "", JSON.stringify(result.counts), result.error || ""); sendResponse({ ok: true, result }); })
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

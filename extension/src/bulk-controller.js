// Atelier Capture — the content-script bulk controller (Phase 6, [1A]).
//
// Runs in the page (durable while the tab is open, so it survives the SW being torn
// down mid-sweep — the MV3 [A1] requirement). It owns the sweep: open a job, load the
// known-source skip set, drive the engine over the platform driver, relay each item
// to the SW, checkpoint to chrome.storage, close the job. All localhost I/O is
// proxied to the SW via an injected `transport` (chrome.runtime.sendMessage), so the
// orchestration CORE (`runBulkSweep`) is pure and unit-tested with a fake transport.
//
// The chrome.*/window bootstrap (build the platform driver from the live page, wire
// the X hook's messages, checkpoint store) is thin guarded glue at the tail —
// exercised by manual E2E (Phase 9), not node --test.

import { runSweep, classifyIngestResult } from "./bulk-engine.js";
import {
  BULK, START, TIMELINE_MESSAGE_SOURCE, TIMELINE_REPLAY_SOURCE, readStartMessage,
} from "./bulk-messages.js";
import {
  pinterestBoardDriver, makeResourceFetch, scrapePinterestAppVersionFromDoc, readCookie,
} from "./bulk-pinterest.js";
import { createTwitterSource } from "./twitter-source.js";

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
    return classifyIngestResult(result);
  };

  const result = await runSweep(driver, input, {
    relay, knownSet, storage: checkpointStorage, checkpointKey,
    config, onProgress, sleep, random, log,
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

  return { jobId, caps, ...result };
}

/** A stable per-target checkpoint key: the same board / bookmarks-set resumes across
 * runs. Prefers the concrete board id, falls back to the scope, then the platform. */
export function sweepCheckpointKey({ platform, scope = null, input = null }) {
  const target = (input && input.boardId) || scope || "default";
  return `atelier:bulk:${platform}:${target}`;
}

// ---------------------------------------------------------------------------
// Content-script bootstrap (chrome.*/window glue — guarded; E2E-verified)
// ---------------------------------------------------------------------------

/** A `transport` backed by `chrome.runtime.sendMessage`, surfacing an error reply
 * (see the SW glue in sw.js) as a thrown error the controller can halt on. */
export function makeRuntimeTransport(sendMessage) {
  return async (message) => {
    const reply = await sendMessage(message);
    if (reply && reply.__error) throw new Error(reply.__error);
    return reply;
  };
}

/** A `{ load, save, remove }` checkpoint store over `chrome.storage.local`. */
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
function buildTwitterDriver({ win, host, scope }) {
  const source = createTwitterSource({
    host,
    scope,
    scroll: () => win.scrollTo(0, win.document.body.scrollHeight),
  });
  const onMessage = (event) => {
    if (event.source === win && event.data && event.data.source === TIMELINE_MESSAGE_SOURCE) {
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
  return { driver: source, dispose: () => win.removeEventListener("message", onMessage) };
}

/** Register the START-message listener on a page. Extracted so the guard + wiring are
 * one place; idempotent via a window flag so a re-injection (the cold-tab recovery in
 * bulk-dispatch.js) can't leave two listeners → two sweeps for one click. */
export function registerBulkController(win, chromeApi) {
  if (win.__atelierBulkController) return; // already wired on this page
  win.__atelierBulkController = true;

  chromeApi.runtime.onMessage.addListener((message, _sender, sendResponse) => {
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
    if (spec.platform !== "twitter" && spec.platform !== "pinterest") {
      sendResponse({ ok: false, error: `unsupported-platform: ${spec.platform}` });
      return true;
    }
    win.__atelierSweepInFlight = true;

    const transport = makeRuntimeTransport((m) => chromeApi.runtime.sendMessage(m));
    const storage = makeChromeStorage(chromeApi.storage.local);
    const host = win.location.host;
    const { driver, dispose } = spec.platform === "twitter"
      ? buildTwitterDriver({ win, host, scope: spec.scope })
      : buildPinterestDriver({ doc: win.document, loc: win.location, fetchImpl: win.fetch.bind(win) });
    runBulkSweep(spec, { transport, driver, storage })
      .then((result) => sendResponse({ ok: true, result }))
      .catch((error) => sendResponse({ ok: false, error: String(error) }))
      .finally(() => { win.__atelierSweepInFlight = false; dispose(); }); // release guard + tear down listener
    return true; // async sendResponse
  });
}

// Guarded so a `node --test` import (no chrome / window) is inert. The real bootstrap
// is triggered by a START runtime message from the popup (or the injection recovery).
if (typeof chrome !== "undefined" && chrome.runtime && typeof window !== "undefined") {
  registerBulkController(window, chrome);
}

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
import { BULK, TIMELINE_MESSAGE_SOURCE } from "./bulk-messages.js";
import {
  pinterestBoardDriver, makeResourceFetch, scrapePinterestAppVersion, readCookie,
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

  const { jobId, caps } = await transport({ type: BULK.open, platform, scope, totalEstimate });
  const knownSet = new Set(await transport({ type: BULK.known, jobId }));

  // Checkpoint under a STABLE per-target key (the board / bookmarks-set), NOT the
  // jobId — every run opens a fresh job, so a jobId-scoped key would strand the
  // saved cursor and force a full re-enumeration on resume. Keyed this way, a
  // killed run's cursor is exactly what the next run reads back.
  const checkpointKey = sweepCheckpointKey({ platform, scope, input });

  // Relay each item to the SW (only it can reach localhost); classify its result
  // into the engine's outcome taxonomy. Video is opt-in — the resolved MP4 lives in
  // the mapped provenance, so no extra network call is needed to find it.
  const relay = async (item) => {
    const result = await transport({
      type: BULK.relay,
      jobId,
      sourceId: item.sourceId,
      provenance: item.provenance,
      mp4Url: resolveVideo ? (item.provenance?.rawMetadata?.videoUrl || null) : null,
    });
    return classifyIngestResult(result);
  };

  const result = await runSweep(driver, input, {
    relay, knownSet, storage, checkpointKey,
    config, onProgress, sleep, random, log,
  });

  // Map the engine's terminal state to the ledger close status (7A): a halt pauses
  // the job (resumable); a clean finish completes it.
  await transport({
    type: BULK.complete, jobId,
    status: result.status === "halted" ? "halted" : "complete",
  });

  // A clean finish clears the checkpoint so a later re-sweep starts fresh (and picks
  // up items added since); a halt KEEPS it so the next run resumes from the cursor.
  if (result.status !== "halted" && storage && storage.remove) {
    await storage.remove(checkpointKey);
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
 * `/resource/` fetch, app-version scraped from the bootstrap, csrftoken from cookie. */
function buildPinterestDriver({ doc, loc, fetchImpl }) {
  const appVersion = scrapePinterestAppVersion(doc.documentElement.innerHTML);
  const csrfToken = readCookie(doc.cookie, "csrftoken");
  const fetchJson = makeResourceFetch({ appVersion, csrfToken, fetchImpl });
  return pinterestBoardDriver({ fetchJson, host: loc.host });
}

/** Build the X driver: subscribe to the MAIN-world hook's timeline messages and
 * feed them to the push→pull source, which auto-scrolls to page. */
function buildTwitterDriver({ win, host }) {
  const source = createTwitterSource({
    host,
    scroll: () => win.scrollTo(0, win.document.body.scrollHeight),
  });
  win.addEventListener("message", (event) => {
    if (event.source === win && event.data && event.data.source === TIMELINE_MESSAGE_SOURCE) {
      source.onResponse(event.data.json);
    }
  });
  return source;
}

// Guarded so a `node --test` import (no chrome / window) is inert. The real
// bootstrap is triggered by a "start sweep" runtime message from the app-driven UI.
if (typeof chrome !== "undefined" && chrome.runtime && typeof window !== "undefined") {
  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!message || message.type !== "atelier-bulk-start") return false;
    const transport = makeRuntimeTransport((m) => chrome.runtime.sendMessage(m));
    const storage = makeChromeStorage(chrome.storage.local);
    const host = window.location.host;
    const driver = message.platform === "twitter"
      ? buildTwitterDriver({ win: window, host })
      : buildPinterestDriver({ doc: document, loc: window.location, fetchImpl: window.fetch.bind(window) });
    runBulkSweep(
      { platform: message.platform, input: message.input, scope: message.scope, resolveVideo: message.resolveVideo },
      { transport, driver, storage })
      .then((result) => sendResponse({ ok: true, result }))
      .catch((error) => sendResponse({ ok: false, error: String(error) }));
    return true; // async sendResponse
  });
}

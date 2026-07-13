// Atelier Capture — the service worker (the ONLY code that talks to localhost).
//
// On a user gesture (toolbar click or context-menu "Save to Atelier"), it:
//   1. injects harvestSignals into the active tab to read a raw page snapshot,
//   2. shapes it (buildHarvest) and computes provenance off-page via the pure
//      extractors,
//   3. fetches the media bytes in the authenticated session (base64 image, or a
//      streamed video Blob),
//   4. POSTs to the app's loopback endpoint with the shared-secret token,
//   5. flashes a result badge.
//
// Doing the fetch + POST here (not in a content script) is required by MV3: only
// the SW, with host_permissions, may reach http://127.0.0.1 without CORS trouble.
//
// STRUCTURE: the decision-making core (`captureCore`, `fetchImage`,
// `presentation`) is pure/injectable and unit-tested (sw.test.js). The `chrome.*`
// event wiring at the bottom is thin glue, registered only in a real extension
// (guarded so this module imports cleanly under `node --test`).

import { harvestSignals, buildHarvest } from "./harvest.js";
import { extractProvenance } from "./extractors/registry.js";
import {
  buildCaptureRequest, buildContentCaptureRequest, tweetContent,
  postCapture, buildProvenanceHeader, postVideoCapture,
} from "./endpoint.js";
import {
  resolveTwitterVideo, shouldResolveVideo as twitterHasVideo,
} from "./twitter-video.js";
import {
  resolvePinterestVideo, shouldResolveVideo as pinterestHasVideo,
} from "./pinterest-video.js";
import { fetchWithTimeout } from "./net.js";
import { MAX_VIDEO_BYTES } from "./config.js";
import { isBulkMessage } from "./bulk-messages.js";
import { handleBulkMessage } from "./bulk-sw.js";
import { openJob, fetchKnownSources, completeJob } from "./bulk-endpoint.js";

const TOKEN_KEY = "atelierToken";
const B64_CHUNK = 0x8000; // 32 KB per String.fromCharCode.apply — see bytesToBase64

// ---------------------------------------------------------------------------
// Core (pure / injectable — no chrome.*), unit-tested.
// ---------------------------------------------------------------------------

/** Base64 of a byte array, chunked so a large image doesn't do millions of
 * single-char string concatenations (which janked the SW on big captures).
 * `endpoint.js`'s `base64Utf8` stays separate — it only encodes small strings. */
function bytesToBase64(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += B64_CHUNK) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + B64_CHUNK));
  }
  return btoa(binary);
}

/**
 * Fetch the first working URL (in the authenticated session) and base64-encode
 * the bytes. Tries each candidate in order so a full-res URL that 404s falls back
 * to the rendered one. REQUIRES an `image/*` content-type — a non-image type OR a
 * MISSING one (3B) is refused, so an error/login/HTML page (which often omits the
 * header entirely) can't be "successfully" ingested as garbage bytes. Throws if none
 * succeed. Returns `{ base64, url, contentType, byteLength }`. `fetchImpl` is injectable.
 * `maxBytes` (13A — the server's authoritative image-body cap for a bulk sweep) rejects
 * an over-cap image from its declared Content-Length BEFORE reading the body (mirroring
 * the video path), so a doomed huge file isn't fully downloaded only to be 413'd. Null
 * (single-item capture) skips the pre-check; the server stays the backstop either way.
 */
export async function fetchImage(urls, { fetchImpl = fetch, maxBytes = null } = {}) {
  let lastError = new Error("No media URL to fetch.");
  for (const url of urls) {
    try {
      const response = await fetchWithTimeout(url, {}, { fetchImpl });
      if (!response.ok) {
        // Carry the numeric status on the error so ingestOne can surface it (5A): the
        // engine's classifier turns a 401/403 into a resumable auth-wall halt.
        lastError = Object.assign(new Error(`HTTP ${response.status} for ${url}`),
          { httpStatus: response.status });
        continue;
      }
      const contentType = response.headers.get("content-type") || "";
      if (!contentType.startsWith("image/")) {
        lastError = new Error(`Non-image response (${contentType || "no content-type"}) for ${url}`);
        continue;
      }
      // Declared-size pre-check (13A). Over-cap → skip to the next candidate (a smaller
      // rendered variant may fit). Absent Content-Length → proceed; the server caps it.
      if (maxBytes) {
        const declared = Number(response.headers.get("content-length") || 0);
        if (declared > maxBytes) {
          lastError = new Error(`image too large (${declared} > ${maxBytes} bytes) for ${url}`);
          continue;
        }
      }
      const bytes = new Uint8Array(await response.arrayBuffer());
      return {
        base64: bytesToBase64(bytes),
        url,
        contentType: contentType || null,
        byteLength: bytes.length,
      };
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError;
}

/** Download the resolved MP4 and POST it to the video endpoint. Returns
 * `{ deduplicated }`; THROWS on any failure so the caller can fall back to the
 * poster image. The body is a `Blob` (browser-backed, streamed on send) so the
 * whole clip never sits in the JS heap. A non-200 ingest also throws. `maxBytes`
 * (13A — the server's authoritative video cap for a bulk sweep) overrides the
 * `MAX_VIDEO_BYTES` default; null/absent falls back to that constant (single-item). */
export async function downloadAndIngestVideo(
  provenance, mp4Url, token, { fetchImpl = fetch, jobId = null, sourceId = null, maxBytes = null } = {}
) {
  const response = await fetchWithTimeout(mp4Url, {}, { fetchImpl });
  if (!response.ok) throw new Error(`video HTTP ${response.status} for ${mp4Url}`);
  const contentType = response.headers.get("content-type") || "";
  if (contentType && !contentType.startsWith("video/")) {
    throw new Error(`non-video response (${contentType})`);
  }
  // Reject an over-cap clip from its declared size BEFORE reading the body, so a
  // huge MP4 isn't fully downloaded only for the server to 413 it. (Absent on a
  // chunked response — then we proceed and the server's cap is the backstop.) The
  // server's authoritative cap (13A) overrides the local default when supplied.
  const limit = maxBytes || MAX_VIDEO_BYTES;
  const declaredBytes = Number(response.headers.get("content-length") || 0);
  if (declaredBytes > limit) {
    throw new Error(`video too large (${declaredBytes} > ${limit} bytes)`);
  }
  const blob = await response.blob();
  const { status, body } = await postVideoCapture(blob, {
    token,
    provenanceHeader: buildProvenanceHeader(provenance, { jobId, sourceId }),
  });
  if (status !== 200) throw new Error(body.error || `ingest HTTP ${status}`);
  return { deduplicated: !!body.deduplicated };
}

/** Real implementations the core uses; overridden wholesale in tests. */
const defaultDeps = {
  extractProvenance,
  twitterHasVideo,
  resolveTwitterVideo,
  pinterestHasVideo,
  resolvePinterestVideo,
  fetchImage,
  downloadAndIngestVideo,
  buildCaptureRequest,
  buildContentCaptureRequest,
  tweetContent,
  postCapture,
  log: (...args) => console.log("[Atelier]", ...args),
  logError: (...args) => console.error("[Atelier]", ...args),
};

/**
 * The full capture decision, as a pure function returning a semantic result (the
 * glue maps it to a badge via `presentation`). Fail-OPEN on video: a resolution
 * failure is EXPECTED (not a video / the platform API changed) → quiet log; a
 * RESOLVED video that then fails to download/ingest is UNEXPECTED → loud log; both
 * fall back to the still image, so a capture is never worse than before.
 */
export async function captureCore(harvest, context, token, deps = defaultDeps) {
  const provenance = deps.extractProvenance(harvest, context);
  if (!provenance.mediaUrl) return { status: "no-image" };
  if (!token) return { status: "no-token" };

  // Video DETECTION + resolution is single-item-specific: it reads harvest/context
  // (the bulk engine resolves video from structured JSON instead). A failure here
  // is EXPECTED (not a video / the platform API changed) → quiet log, fall through.
  // The resolved mp4Url (or null) is handed to the shared ingestOne tail.
  let mp4Url = null;
  try {
    if (deps.twitterHasVideo(provenance, context)) {
      mp4Url = await deps.resolveTwitterVideo(provenance.rawMetadata.tweetId);
    } else if (deps.pinterestHasVideo(provenance, harvest)) {
      mp4Url = await deps.resolvePinterestVideo(provenance.rawMetadata.pinId);
    }
  } catch (error) {
    deps.log("no video / resolution failed → image fallback:", String(error));
    mp4Url = null;
  }

  // A single-item tweet capture (003 · C3, Option 3): when this is a usable tweet,
  // POST it as a `tweet` content item carrying its card image, so it lands as a
  // first-class tweet (payload + picture) rather than a bare image. `null` for a
  // non-tweet (or a tweet with no id/substance) → the plain image path. The bulk X
  // sweep does NOT set this — it stays on the image path for now.
  const content = deps.tweetContent(provenance);
  return ingestOne(provenance, { token, mp4Url, content }, deps);
}

/**
 * The shared ingest TAIL (decision 5A): given a `provenance` and an already-
 * resolved optional `mp4Url`, fetch the media bytes in the authenticated session
 * and POST to the app — the SAME path single-item capture and the bulk engine both
 * use. `jobId`+`sourceId` (bulk, 3A) tag the POST so the app records a job_item;
 * single-item capture omits them. Fail-OPEN on video: a RESOLVED video that then
 * fails to download/ingest is UNEXPECTED → loud log, then falls back to the still
 * image, so a capture is never worse than before. Pure/injectable — no chrome.*.
 */
export async function ingestOne(
  provenance,
  { token, mp4Url = null, jobId = null, sourceId = null, caps = null, content = null } = {},
  deps = defaultDeps
) {
  // Server byte caps (13A): a bulk relay carries the job's authoritative limits so the
  // pre-download size checks use them; single-item capture passes no caps (null → the
  // local defaults / no image pre-check apply, with the server as backstop).
  const maxImageBytes = caps ? (caps.maxBodyBytes ?? null) : null;
  const maxVideoBytes = caps ? (caps.maxVideoBodyBytes ?? null) : null;

  if (mp4Url) {
    try {
      const { deduplicated } = await deps.downloadAndIngestVideo(
        provenance, mp4Url, token, { jobId, sourceId, maxBytes: maxVideoBytes });
      return { status: "saved", kind: "video", deduplicated };
    } catch (error) {
      // A resolved video should normally ingest — log loudly, but still fall back.
      deps.logError("resolved video failed to download/ingest → image fallback:", error);
    }
  }

  // Build the POST body. A media-less content item (a text-only tweet has NO card
  // image) posts kind+payload with no image → the server's `.content` text-card path.
  // This fires ONLY when there's genuinely no media URL to fetch; a FETCH FAILURE must
  // still surface as fetch-error (so a 401/403 auth wall halts the sweep, 5A), never
  // silently downgrade a picture tweet to a text card.
  let request;
  if (content && !provenance.mediaUrl) {
    request = deps.buildContentCaptureRequest(provenance, null, content, { jobId, sourceId });
  } else {
    let fetched;
    try {
      fetched = await deps.fetchImage(
        [provenance.mediaUrl, provenance.mediaUrlFallback].filter(Boolean),
        { maxBytes: maxImageBytes }
      );
    } catch (error) {
      // Thread the CDN's HTTP status through (5A) so a 401/403 auth wall halts the sweep
      // resumable rather than burning through the rest of the board as permanent fails.
      return {
        status: "fetch-error",
        httpStatus: error.httpStatus ?? null,
        message: `Could not fetch the image (${String(error)}).`,
      };
    }
    // A tweet content-capture (Option 3) carries the SAME card-image bytes but as a
    // `tweet` content item (kind + payload); otherwise the plain image body.
    request = content
      ? deps.buildContentCaptureRequest(provenance, fetched.base64, content, { jobId, sourceId })
      : deps.buildCaptureRequest(provenance, fetched.base64, { jobId, sourceId });
  }

  try {
    const { status, body } = await deps.postCapture(request, { token });
    if (status === 200) {
      const result = {
        status: "saved", kind: content ? "tweet" : "image",
        deduplicated: !!body.deduplicated,
      };
      // Bulk relay feedback (7A): the app stamps the job's status on a tagged reply
      // so a user pause/cancel halts the sweep. Absent on single-item captures.
      if (body.jobStatus) result.jobStatus = body.jobStatus;
      return result;
    }
    // Surface the app's status (5A): a 401/403 (bad/expired token) is an auth wall the
    // classifier halts on; a 5xx is transient; other 4xx are per-item permanent.
    return { status: "ingest-error", httpStatus: status, message: body.error || `HTTP ${status}` };
  } catch {
    return { status: "unreachable" };
  }
}

/** Map a capture result to a badge `{ text, color, title }`. */
export function presentation(result) {
  switch (result.status) {
    case "no-image":
      return { text: "?", color: "#e08c00", title: "No image found on this page." };
    case "no-token":
      return { text: "KEY", color: "#e08c00", title: "Set your Atelier token in the extension options." };
    case "saved":
      return {
        text: "✓", color: "#2e8b57",
        title: result.deduplicated
          ? "Already saved."
          : result.kind === "video" ? "Saved video to Atelier." : "Saved to Atelier.",
      };
    case "ingest-error":
      return { text: "ERR", color: "#cc3333", title: result.message || "Ingest failed." };
    case "fetch-error":
      return { text: "ERR", color: "#cc3333", title: result.message || "Could not fetch the image." };
    case "unreachable":
      return { text: "ERR", color: "#cc3333", title: "Could not reach Atelier — is the app running?" };
    default:
      return { text: "ERR", color: "#cc3333", title: String(result.message || "Capture failed.") };
  }
}

// ---------------------------------------------------------------------------
// Glue (chrome.*) — thin, registered only in a real extension.
// ---------------------------------------------------------------------------

/** The saved shared-secret token, or "" if unset. */
async function getToken() {
  const stored = await chrome.storage.local.get(TOKEN_KEY);
  return stored[TOKEN_KEY] || "";
}

/** Full capture flow for one tab, given the right-clicked `context` (or {}). */
async function capture(tab, context) {
  if (!tab?.id) return;
  clearBadge(); // 8A: drop any stale badge from a prior capture up front

  let raw;
  try {
    const [injection] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: harvestSignals,
    });
    raw = injection?.result;
  } catch {
    return flash("ERR", "#cc3333", "Could not read the page.");
  }
  if (!raw) return flash("ERR", "#cc3333", "Could not read the page.");

  const harvest = buildHarvest(raw);
  const token = await getToken();
  const result = await captureCore(harvest, context, token);
  const { text, color, title } = presentation(result);
  flash(text, color, title);
}

/** Brief action-badge feedback (title carries the full message). */
function flash(text, color, title) {
  chrome.action.setBadgeBackgroundColor({ color });
  chrome.action.setBadgeText({ text });
  if (title) chrome.action.setTitle({ title: `Atelier — ${title}` });
  // Best-effort auto-clear; an MV3 SW may be torn down before it fires, so the
  // next capture also clears the badge up front (see capture()).
  setTimeout(() => chrome.action.setBadgeText({ text: "" }), 4000);
}

/** Clear the badge immediately (no title change). */
function clearBadge() {
  chrome.action.setBadgeText({ text: "" });
}

if (typeof chrome !== "undefined" && chrome.runtime && chrome.runtime.onMessage) {
  // Thin bulk relay: the content-script controller messages the SW for every
  // localhost op (only the SW reaches 127.0.0.1). Each message resets the SW idle
  // timer, which is what keeps it alive across a long sweep. An error is returned as
  // an `{ __error }` envelope the controller's transport rethrows (→ engine halt).
  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!isBulkMessage(message)) return false;
    getToken()
      .then((token) => handleBulkMessage(message, {
        token, fetchImpl: fetch, ingestOne, openJob, fetchKnownSources, completeJob,
      }))
      .then((payload) => sendResponse(payload))
      .catch((error) => sendResponse({ __error: String(error) }));
    return true; // keep the message channel open for the async sendResponse
  });
}

if (typeof chrome !== "undefined" && chrome.action) {
  // NB: the toolbar action now opens the popup (manifest `action.default_popup`), so
  // `chrome.action.onClicked` no longer fires — single-item capture lives on the
  // right-click context menu below (and the popup launches sweeps).
  chrome.runtime.onInstalled.addListener(() => {
    // removeAll first so a re-install/update can't throw "duplicate id".
    chrome.contextMenus.removeAll(() => {
      chrome.contextMenus.create({
        id: "atelier-save",
        title: "Save to Atelier",
        contexts: ["page", "image", "link"],
      });
    });
  });

  chrome.contextMenus.onClicked.addListener((info, tab) => {
    // The right-clicked element: exact image + its link — far more reliable than
    // guessing from the page (esp. capturing a pin from the feed).
    const context = {
      srcUrl: info.srcUrl || null,
      linkUrl: info.linkUrl || null,
      pageUrl: info.pageUrl || null,
    };
    if (tab) capture(tab, context).catch((error) => flash("ERR", "#cc3333", String(error)));
  });
}

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
  buildCaptureRequest, postCapture, buildProvenanceHeader, postVideoCapture,
} from "./endpoint.js";
import {
  resolveTwitterVideo, shouldResolveVideo as twitterHasVideo,
} from "./twitter-video.js";
import {
  resolvePinterestVideo, shouldResolveVideo as pinterestHasVideo,
} from "./pinterest-video.js";
import { fetchWithTimeout } from "./net.js";

const TOKEN_KEY = "atelierToken";
const B64_CHUNK = 0x8000; // 32 KB per String.fromCharCode.apply — see bytesToBase64
// Mirror of the server's video cap (CaptureServer.defaultMaxVideoBodyBytes). A
// client-side early-out via Content-Length so a doomed huge MP4 isn't downloaded
// in full before the server's 413. Kept in sync with AtelierServer by hand.
const MAX_VIDEO_BYTES = 512 * 1024 * 1024;

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
 * to the rendered one. Rejects non-image content-types (an error/HTML page would
 * otherwise be "successfully" ingested as garbage). Throws if none succeed.
 * Returns `{ base64, url, contentType, byteLength }`. `fetchImpl` is injectable.
 */
export async function fetchImage(urls, { fetchImpl = fetch } = {}) {
  let lastError = new Error("No media URL to fetch.");
  for (const url of urls) {
    try {
      const response = await fetchWithTimeout(url, {}, { fetchImpl });
      if (!response.ok) {
        lastError = new Error(`HTTP ${response.status} for ${url}`);
        continue;
      }
      const contentType = response.headers.get("content-type") || "";
      if (contentType && !contentType.startsWith("image/")) {
        lastError = new Error(`Non-image response (${contentType}) for ${url}`);
        continue;
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
 * whole clip never sits in the JS heap. A non-200 ingest also throws. */
export async function downloadAndIngestVideo(provenance, mp4Url, token, { fetchImpl = fetch } = {}) {
  const response = await fetchWithTimeout(mp4Url, {}, { fetchImpl });
  if (!response.ok) throw new Error(`video HTTP ${response.status} for ${mp4Url}`);
  const contentType = response.headers.get("content-type") || "";
  if (contentType && !contentType.startsWith("video/")) {
    throw new Error(`non-video response (${contentType})`);
  }
  // Reject an over-cap clip from its declared size BEFORE reading the body, so a
  // huge MP4 isn't fully downloaded only for the server to 413 it. (Absent on a
  // chunked response — then we proceed and the server's cap is the backstop.)
  const declaredBytes = Number(response.headers.get("content-length") || 0);
  if (declaredBytes > MAX_VIDEO_BYTES) {
    throw new Error(`video too large (${declaredBytes} > ${MAX_VIDEO_BYTES} bytes)`);
  }
  const blob = await response.blob();
  const { status, body } = await postVideoCapture(blob, {
    token,
    provenanceHeader: buildProvenanceHeader(provenance),
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
  if (mp4Url) {
    try {
      const { deduplicated } = await deps.downloadAndIngestVideo(provenance, mp4Url, token);
      return { status: "saved", kind: "video", deduplicated };
    } catch (error) {
      // A resolved video should normally ingest — log loudly, but still fall back.
      deps.logError("resolved video failed to download/ingest → image fallback:", error);
    }
  }

  let fetched;
  try {
    fetched = await deps.fetchImage(
      [provenance.mediaUrl, provenance.mediaUrlFallback].filter(Boolean)
    );
  } catch (error) {
    return { status: "fetch-error", message: `Could not fetch the image (${String(error)}).` };
  }

  const request = deps.buildCaptureRequest(provenance, fetched.base64);
  try {
    const { status, body } = await deps.postCapture(request, { token });
    if (status === 200) {
      return { status: "saved", kind: "image", deduplicated: !!body.deduplicated };
    }
    return { status: "ingest-error", message: body.error || `HTTP ${status}` };
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

if (typeof chrome !== "undefined" && chrome.action) {
  chrome.action.onClicked.addListener((tab) => {
    capture(tab, {}).catch((error) => flash("ERR", "#cc3333", String(error)));
  });

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

// Atelier Capture — the service worker (the ONLY code that talks to localhost).
//
// On a user gesture (toolbar click or context-menu "Save to Atelier"), it:
//   1. injects harvestSignals into the active tab (page context) to read signals,
//   2. computes provenance off-page via the pure extractors,
//   3. fetches the media bytes in the authenticated session and base64-encodes,
//   4. POSTs to the app's loopback endpoint with the shared-secret token,
//   5. flashes a result badge.
//
// Doing the fetch + POST here (not in a content script) is required by MV3: only
// the SW, with host_permissions, may reach http://127.0.0.1 without CORS trouble.

import { harvestSignals } from "./harvest.js";
import { extractProvenance } from "./extractors/registry.js";
import {
  buildCaptureRequest, postCapture, DEFAULT_ENDPOINT,
  buildProvenanceHeader, postVideoCapture,
} from "./endpoint.js";
import { resolveTwitterVideo } from "./twitter-video.js";

const TOKEN_KEY = "atelierToken";

chrome.action.onClicked.addListener((tab) => {
  capture(tab, {}).catch((error) => flash("ERR", "#cc3333", String(error)));
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "atelier-save",
    title: "Save to Atelier",
    contexts: ["page", "image", "link"],
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

/** Full capture flow for one tab, given the right-clicked `context` (or {}). */
async function capture(tab, context) {
  if (!tab?.id) return;

  const [injection] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func: harvestSignals,
  });
  const harvest = injection?.result;
  if (!harvest) return flash("ERR", "#cc3333", "Could not read the page.");

  const provenance = extractProvenance(harvest, context);
  console.log("[Atelier] capture", { context, provenance: logSafe(provenance) });
  if (!provenance.mediaUrl) {
    return flash("?", "#e08c00", "No image found on this page.");
  }

  const token = await getToken();
  if (!token) {
    return flash("KEY", "#e08c00", "Set your Atelier token in the extension options.");
  }

  // A video tweet: try to download the ACTUAL MP4 (via the syndication API). Any
  // failure (resolution, fetch, or a non-200 ingest) falls through to the image
  // path below, which captures the poster/frame — never worse than before.
  if (provenance.mediaKind === "video" && provenance.platform === "twitter") {
    const tweetId = provenance.rawMetadata?.tweetId;
    if (tweetId) {
      try {
        await captureVideo(provenance, tweetId, token);
        return;
      } catch (error) {
        console.log("[Atelier] video capture failed → poster fallback", String(error));
      }
    }
  }

  const fetched = await fetchImage(
    [provenance.mediaUrl, provenance.mediaUrlFallback].filter(Boolean)
  );
  console.log("[Atelier] fetched image", {
    url: fetched.url,
    contentType: fetched.contentType,
    bytes: fetched.byteLength,
  });
  const request = buildCaptureRequest(provenance, fetched.base64);

  try {
    const { status, body } = await postCapture(request, {
      endpoint: DEFAULT_ENDPOINT,
      token,
    });
    console.log("[Atelier] ingest response", { status, body });
    if (status === 200) {
      flash("✓", "#2e8b57", body.deduplicated ? "Already saved." : "Saved to Atelier.");
    } else {
      flash("ERR", "#cc3333", body.error || `HTTP ${status}`);
    }
  } catch {
    flash("ERR", "#cc3333", "Could not reach Atelier — is the app running?");
  }
}

/** Download a video tweet's actual MP4 and POST it to the video endpoint. Flashes
 * success; THROWS on any failure so the caller can fall back to the poster image.
 * A non-200 ingest also throws (the poster path may still succeed). */
async function captureVideo(provenance, tweetId, token) {
  const mp4Url = await resolveTwitterVideo(tweetId);
  const response = await fetch(mp4Url);
  if (!response.ok) throw new Error(`video HTTP ${response.status} for ${mp4Url}`);
  const contentType = response.headers.get("content-type") || "";
  if (contentType && !contentType.startsWith("video/")) {
    throw new Error(`non-video response (${contentType})`);
  }
  const bytes = new Uint8Array(await response.arrayBuffer());
  console.log("[Atelier] fetched video", { url: mp4Url, contentType, bytes: bytes.length });

  const { status, body } = await postVideoCapture(bytes, {
    token,
    provenanceHeader: buildProvenanceHeader(provenance),
  });
  console.log("[Atelier] ingest-video response", { status, body });
  if (status !== 200) throw new Error(body.error || `ingest HTTP ${status}`);
  flash("✓", "#2e8b57", body.deduplicated ? "Already saved." : "Saved video to Atelier.");
}

/** The saved shared-secret token, or "" if unset. */
async function getToken() {
  const stored = await chrome.storage.local.get(TOKEN_KEY);
  return stored[TOKEN_KEY] || "";
}

/**
 * Fetch the first working URL (in the authenticated session) and base64-encode
 * the bytes. Tries each candidate in order so a full-res URL that 404s falls back
 * to the rendered one. Rejects non-image content-types (an error/HTML page would
 * otherwise be "successfully" ingested as garbage). Throws if none succeed.
 * Returns `{ base64, url, contentType, byteLength }`.
 */
async function fetchImage(urls) {
  let lastError = new Error("No media URL to fetch.");
  for (const url of urls) {
    try {
      const response = await fetch(url);
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
      let binary = "";
      for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
      return {
        base64: btoa(binary),
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

/** A log-friendly copy of provenance: a captured video frame is a multi-MB
 * data-URL, so summarize any data-URL field rather than dumping it. */
function logSafe(provenance) {
  const shorten = (v) =>
    typeof v === "string" && v.startsWith("data:")
      ? `${v.slice(0, v.indexOf(",") + 1)}…(${v.length} chars)`
      : v;
  return { ...provenance, mediaUrl: shorten(provenance.mediaUrl) };
}

/** Brief action-badge feedback (title carries the full message). */
function flash(text, color, title) {
  chrome.action.setBadgeBackgroundColor({ color });
  chrome.action.setBadgeText({ text });
  if (title) chrome.action.setTitle({ title: `Atelier — ${title}` });
  setTimeout(() => chrome.action.setBadgeText({ text: "" }), 4000);
}

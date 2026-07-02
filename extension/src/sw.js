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
import { buildCaptureRequest, postCapture, DEFAULT_ENDPOINT } from "./endpoint.js";

const TOKEN_KEY = "atelierToken";

chrome.action.onClicked.addListener((tab) => {
  capture(tab).catch((error) => flash("ERR", "#cc3333", String(error)));
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "atelier-save",
    title: "Save to Atelier",
    contexts: ["page", "image", "link"],
  });
});

chrome.contextMenus.onClicked.addListener((_info, tab) => {
  if (tab) capture(tab).catch((error) => flash("ERR", "#cc3333", String(error)));
});

/** Full capture flow for one tab. */
async function capture(tab) {
  if (!tab?.id) return;

  const [injection] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func: harvestSignals,
  });
  const harvest = injection?.result;
  if (!harvest) return flash("ERR", "#cc3333", "Could not read the page.");

  const provenance = extractProvenance(harvest);
  if (!provenance.mediaUrl) {
    return flash("?", "#e08c00", "No image found on this page.");
  }

  const token = await getToken();
  if (!token) {
    return flash("KEY", "#e08c00", "Set your Atelier token in the extension options.");
  }

  const imageBase64 = await fetchImageBase64(
    [provenance.mediaUrl, provenance.mediaUrlFallback].filter(Boolean)
  );
  const request = buildCaptureRequest(provenance, imageBase64);

  try {
    const { status, body } = await postCapture(request, {
      endpoint: DEFAULT_ENDPOINT,
      token,
    });
    if (status === 200) {
      flash("✓", "#2e8b57", body.deduplicated ? "Already saved." : "Saved to Atelier.");
    } else {
      flash("ERR", "#cc3333", body.error || `HTTP ${status}`);
    }
  } catch {
    flash("ERR", "#cc3333", "Could not reach Atelier — is the app running?");
  }
}

/** The saved shared-secret token, or "" if unset. */
async function getToken() {
  const stored = await chrome.storage.local.get(TOKEN_KEY);
  return stored[TOKEN_KEY] || "";
}

/**
 * Fetch the first working URL (in the authenticated session) and base64-encode
 * the bytes. Tries each candidate in order so a full-res URL that 404s falls back
 * to the rendered one. Throws if none succeed.
 */
async function fetchImageBase64(urls) {
  let lastError = new Error("No media URL to fetch.");
  for (const url of urls) {
    try {
      const response = await fetch(url);
      if (!response.ok) {
        lastError = new Error(`HTTP ${response.status} for ${url}`);
        continue;
      }
      const bytes = new Uint8Array(await response.arrayBuffer());
      let binary = "";
      for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
      return btoa(binary);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError;
}

/** Brief action-badge feedback (title carries the full message). */
function flash(text, color, title) {
  chrome.action.setBadgeBackgroundColor({ color });
  chrome.action.setBadgeText({ text });
  if (title) chrome.action.setTitle({ title: `Atelier — ${title}` });
  setTimeout(() => chrome.action.setBadgeText({ text: "" }), 4000);
}

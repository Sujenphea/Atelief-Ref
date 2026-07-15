// Atelier Capture — Instagram MAIN-world saved-feed hook (thin config over hook-core, [5A][3A]).
//
// Instagram serves the saved-posts feed from `…/api/v1/feed/saved/posts/` (a REST call,
// verified live 2026-07-15 — see 002 §B0), paginated by `next_max_id`. As with X we
// INTERCEPT the RESPONSES via the shared hook-core rather than forge requests: this file
// supplies only IG's request-URL matcher and its message tags; all interception,
// buffering and replay live in hook-core.js. Forwarding is status-blind there, so a 4xx
// `checkpoint_required` / feed-429 challenge body reaches the driver ([3A]).
//
// SELF-CONTAINED — a CLASSIC script (NO import/export): injected as a classic MAIN-world
// script at document_start (before IG's own fetches). The tags below are duplicated from
// bulk-messages.js (an ES module a classic script can't import) — KEEP IN SYNC. The
// matcher is copied to the parser side (bulk-instagram.js) — KEEP IN SYNC.

/** postMessage envelope tag. KEEP IN SYNC with bulk-messages.js `IG_SAVED_MESSAGE_SOURCE`. */
const IG_SAVED_MESSAGE_SOURCE = "atelier-ig-saved";

/** The controller posts this to ask the hook to re-emit its buffered saved-feed
 * responses. KEEP IN SYNC with bulk-messages.js `IG_SAVED_REPLAY_SOURCE`. */
const IG_SAVED_REPLAY_SOURCE = "atelier-ig-saved-replay";

/** True for a saved-posts feed request URL (`…/api/v1/feed/saved/posts/`, with optional
 * `?max_id=` pagination). Flat "All posts" only in v1 — a saved COLLECTION loads from a
 * different path and is deliberately NOT matched (002 · 6A). KEEP IN SYNC with the
 * parser-side copy. */
function isSavedFeedRequest(url) {
  return typeof url === "string" && /\/api\/v1\/feed\/saved\/posts\//.test(url);
}

// Auto-install when injected as a MAIN-world content script on Instagram (guarded so a
// `node --test` import — no `window` — does nothing). hook-core.js, loaded FIRST per the
// manifest order, published `window.__atelierInstallResponseHook`; if it's missing the
// manifest order is wrong — fail LOUDLY (console.error) but NEVER throw into the page.
if (typeof window !== "undefined" && window.location &&
    /(^|\.)instagram\.com$/.test(window.location.hostname)) {
  const installResponseHook = window.__atelierInstallResponseHook;
  if (typeof installResponseHook !== "function") {
    console.error("[Atelier] hook-core.js must load before instagram-hook.js (check manifest order)");
  } else {
    installResponseHook({
      target: window,
      isMatch: isSavedFeedRequest,
      replaySource: IG_SAVED_REPLAY_SOURCE,
      post: (message) =>
        window.postMessage({ source: IG_SAVED_MESSAGE_SOURCE, ...message }, window.location.origin),
    });
  }
}

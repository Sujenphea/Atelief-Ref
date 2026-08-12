// Atelier Capture — X / Twitter MAIN-world timeline hook (thin config over hook-core, [5A]).
//
// X fetches its `Bookmarks` / `BookmarkFolderTimeline` / `Likes` timelines from
// `…/i/api/graphql/…` with a volatile `features` blob + a rotating `queryId` + an
// `x-client-transaction-id` header. Forging those is brittle, so we INTERCEPT the
// RESPONSES via the shared hook-core (which wraps `fetch` + `XHR` and forwards matched
// responses). This file supplies only X's request-URL matcher and its message tags; all
// the interception machinery, buffering and replay live in hook-core.js.
//
// SELF-CONTAINED — a CLASSIC script (NO import/export): injected as a classic MAIN-world
// script at document_start. The constants below are duplicated from bulk-messages.js
// (an ES module a classic script can't import) — KEEP IN SYNC. The matcher is copied to
// the parser side (bulk-twitter.js `matchesScope`) — KEEP IN SYNC. The unit test loads
// THIS file as a classic script and exercises `isTimelineRequest`.

/** postMessage envelope tag. KEEP IN SYNC with bulk-messages.js `TIMELINE_MESSAGE_SOURCE`. */
const TIMELINE_MESSAGE_SOURCE = "atelier-x-timeline";

/** The controller posts this to ask the hook to re-emit its buffered responses. KEEP IN
 * SYNC with bulk-messages.js `TIMELINE_REPLAY_SOURCE`. */
const REPLAY_REQUEST_SOURCE = "atelier-x-timeline-replay";

/** True for a timeline GraphQL request URL (`…/i/api/graphql/{queryId}/{Op}`,
 * Op ∈ Bookmarks | BookmarkFolderTimeline | Likes). A bookmark FOLDER loads via the
 * distinct `BookmarkFolderTimeline` op (verified live) — without it, folder sweeps see
 * no responses and ingest nothing. KEEP IN SYNC with any parser-side copy. */
function isTimelineRequest(url) {
  return typeof url === "string" &&
    /\/i\/api\/graphql\/[^/]+\/(Bookmarks|BookmarkFolderTimeline|Likes)(?:$|[/?])/.test(url);
}

/**
 * Request headers the sweep re-uses to ask X a FOLLOW-UP question in the user's own
 * session — the `TweetDetail` call that expands a bookmarked tweet into its thread.
 * Inheriting them is the same discipline as inheriting the `features` blob: forging
 * auth is brittle and would break on every client change.
 *
 * Deliberately NOT here: `x-client-transaction-id`, which X derives PER REQUEST — a
 * replayed one is worse than none. Nothing on this list leaves the tab.
 * KEEP IN SYNC with bulk-controller.js's expectations.
 */
const FORWARDED_HEADERS = [
  "authorization",
  "x-csrf-token",
  "x-twitter-auth-type",
  "x-twitter-active-user",
  "x-twitter-client-language",
];

// Auto-install when injected as a MAIN-world content script on X (guarded so a
// `node --test` import — no `window` — does nothing). hook-core.js, loaded FIRST per the
// manifest order, published `window.__atelierInstallResponseHook`; if it's missing the
// manifest order is wrong — fail LOUDLY (console.error) but NEVER throw into the page.
if (typeof window !== "undefined" && window.location &&
    /(^|\.)(x|twitter)\.com$/.test(window.location.hostname)) {
  const installResponseHook = window.__atelierInstallResponseHook;
  if (typeof installResponseHook !== "function") {
    console.error("[Atelier] hook-core.js must load before twitter-hook.js (check manifest order)");
  } else {
    installResponseHook({
      target: window,
      isMatch: isTimelineRequest,
      replaySource: REPLAY_REQUEST_SOURCE,
      headerAllowlist: FORWARDED_HEADERS,
      post: (message) =>
        window.postMessage({ source: TIMELINE_MESSAGE_SOURCE, ...message }, window.location.origin),
    });
  }
}

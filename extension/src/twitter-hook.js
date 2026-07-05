// Atelier Capture — X / Twitter MAIN-world timeline hook (Phase 5/6, [4A]).
//
// X fetches its `Bookmarks` / `Likes` timelines from `…/i/api/graphql/…` with a
// large, volatile `features` blob + a rotating `queryId` + an `x-client-transaction-id`
// header (Phase-0 recon). Forging those is brittle, so instead we INTERCEPT: injected
// as a MAIN-world content script at `document_start`, this wraps `window.fetch` and
// forwards a clone of every timeline RESPONSE to the content-script controller via
// `postMessage`. Read-only, best-effort: it must NEVER throw into the page or alter a
// response — a capture miss is acceptable, breaking x.com is not.
//
// SELF-CONTAINED (no imports): a MAIN-world content script is a classic script and
// must run synchronously at document_start, before X's own fetches. The constant +
// predicate are therefore duplicated from bulk-messages.js / bulk-twitter.js — small,
// and kept in sync by the comments below. Only these two are unit-imported.

/** postMessage envelope tag. KEEP IN SYNC with bulk-messages.js `TIMELINE_MESSAGE_SOURCE`. */
export const TIMELINE_MESSAGE_SOURCE = "atelier-x-timeline";

/** True for a timeline GraphQL request URL (`…/i/api/graphql/{queryId}/{Op}`,
 * Op ∈ Bookmarks | Likes). KEEP IN SYNC with any parser-side copy. */
export function isTimelineRequest(url) {
  return typeof url === "string" &&
    /\/i\/api\/graphql\/[^/]+\/(Bookmarks|Likes)(?:$|[/?])/.test(url);
}

/**
 * Wrap `scope.fetch` so a timeline response is cloned and handed to `post({ url,
 * json })`. Idempotent (a flag on `scope` prevents double-wrapping across repeated
 * injections). Returns true if it installed, false if already installed or there's no
 * `fetch`. The clone + parse is fire-and-forget so the page's response is returned
 * untouched and on its original timing.
 */
export function installTimelineHook({ target, post } = {}) {
  const scope = target || (typeof globalThis !== "undefined" ? globalThis : null);
  if (!scope || typeof scope.fetch !== "function") return false;
  if (scope.__atelierTimelineHookInstalled) return false;
  scope.__atelierTimelineHookInstalled = true;

  const originalFetch = scope.fetch.bind(scope);
  scope.fetch = async function (...args) {
    const response = await originalFetch(...args);
    try {
      const input = args[0];
      const url = typeof input === "string" ? input : (input && input.url) || "";
      if (isTimelineRequest(url) && response && typeof response.clone === "function") {
        response.clone().json().then((json) => post({ url, json })).catch(() => {});
      }
    } catch {
      /* never break the page */
    }
    return response;
  };
  return true;
}

// Auto-install when injected as a MAIN-world content script on X (guarded so a
// `node --test` import — no `window` — does nothing).
if (typeof window !== "undefined" && window.location &&
    /(^|\.)(x|twitter)\.com$/.test(window.location.hostname)) {
  installTimelineHook({
    target: window,
    post: (message) =>
      window.postMessage({ source: TIMELINE_MESSAGE_SOURCE, ...message }, window.location.origin),
  });
}

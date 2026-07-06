// Atelier Capture — X / Twitter MAIN-world timeline hook (Phase 5/6, [4A]).
//
// X fetches its `Bookmarks` / `Likes` timelines from `…/i/api/graphql/…` with a
// large, volatile `features` blob + a rotating `queryId` + an `x-client-transaction-id`
// header (Phase-0 recon). Forging those is brittle, so instead we INTERCEPT: injected
// as a MAIN-world content script at `document_start`, this wraps BOTH `window.fetch`
// AND `XMLHttpRequest` and forwards every timeline RESPONSE to the content-script
// controller via `postMessage`. X's live web client issues the timeline over XHR (not
// fetch), so the XHR path is the one that actually fires — the fetch path is kept for
// robustness / other call sites. Read-only, best-effort: it must NEVER throw into the
// page or alter a response — a capture miss is acceptable, breaking x.com is not.
//
// SELF-CONTAINED — a CLASSIC script (NO import/export): a MAIN-world content script is
// injected as a classic script and must run synchronously at document_start, before X's
// own fetches. `export` is a SyntaxError in a classic script (it would silently fail the
// WHOLE file → no hook), so the declarations below stay plain top-level. The constant +
// predicate are duplicated from bulk-messages.js / bulk-twitter.js — small, kept in sync
// by the comments. The unit test loads THIS file as a classic script (readFileSync + new
// Function) and exercises these functions, so there's a single source of truth.

/** postMessage envelope tag. KEEP IN SYNC with bulk-messages.js `TIMELINE_MESSAGE_SOURCE`. */
const TIMELINE_MESSAGE_SOURCE = "atelier-x-timeline";

/** True for a timeline GraphQL request URL (`…/i/api/graphql/{queryId}/{Op}`,
 * Op ∈ Bookmarks | Likes). KEEP IN SYNC with any parser-side copy. */
function isTimelineRequest(url) {
  return typeof url === "string" &&
    /\/i\/api\/graphql\/[^/]+\/(Bookmarks|Likes)(?:$|[/?])/.test(url);
}

/**
 * Wrap `scope.fetch` AND `scope.XMLHttpRequest` so a timeline response is parsed and
 * handed to `post({ url, json })`. Idempotent (a flag on `scope` prevents double-
 * wrapping across repeated injections). Returns true if it installed either
 * interceptor, false if already installed or neither transport exists. Both paths are
 * fire-and-forget and fully guarded — the page's own request is returned untouched, on
 * its original timing, and a parse failure is swallowed.
 */
function installTimelineHook({ target, post } = {}) {
  const scope = target || (typeof globalThis !== "undefined" ? globalThis : null);
  if (!scope) return false;
  if (scope.__atelierTimelineHookInstalled) return false;

  let installed = false;

  // fetch path — a clone is parsed so the page still reads the original body.
  if (typeof scope.fetch === "function") {
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
    installed = true;
  }

  // XHR path — X's live client fetches the timeline here. Stamp the URL at open(),
  // then read the response on `load` (passive listener — never touches the page's own
  // handlers or the response).
  const XHR = scope.XMLHttpRequest;
  if (XHR && XHR.prototype && typeof XHR.prototype.open === "function") {
    const originalOpen = XHR.prototype.open;
    const originalSend = XHR.prototype.send;
    XHR.prototype.open = function (method, url) {
      try { this.__atelierTimelineUrl = url; } catch { /* ignore */ }
      return originalOpen.apply(this, arguments);
    };
    XHR.prototype.send = function () {
      try {
        const url = this.__atelierTimelineUrl;
        if (isTimelineRequest(url)) {
          this.addEventListener("load", function () {
            try {
              const type = this.responseType;
              let json = null;
              if (type === "" || type === "text") json = JSON.parse(this.responseText);
              else if (type === "json") json = this.response;
              if (json) post({ url, json });
            } catch {
              /* ignore a non-JSON / unreadable body */
            }
          });
        }
      } catch {
        /* never break the page */
      }
      return originalSend.apply(this, arguments);
    };
    installed = true;
  }

  if (installed) scope.__atelierTimelineHookInstalled = true;
  return installed;
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

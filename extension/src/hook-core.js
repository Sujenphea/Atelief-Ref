// Atelier Capture — shared MAIN-world response-interception core (Phase 5/6, [5A]).
//
// The machinery a MAIN-world response hook needs, in ONE place: wrap `fetch` AND
// `XMLHttpRequest`, forward the RESPONSE of any request whose URL a per-platform
// `isMatch(url)` accepts to `post({ url, json })`, buffer recent responses (bounded),
// and re-emit them when the controller asks (so a sweep that subscribes late still gets
// the pages fetched before it started). X (twitter-hook.js) is a THIN config over this —
// it supplies only a URL matcher + its message/replay tags. (Instagram does NOT use a
// hook — its saved feed is replayed directly, 002 · O2 — so X is the sole caller today;
// the seam stays generic for the next interceptable platform.)
//
// SELF-CONTAINED — a CLASSIC script (NO import/export): a MAIN-world content script is
// injected as a classic script and must run synchronously at document_start. `export`
// is a SyntaxError in a classic script (it silently fails the WHOLE file → no hook), so
// everything stays plain top-level. The per-site hook is injected AFTER this one
// (manifest order `["src/hook-core.js", "src/<site>-hook.js"]`) and reads the installer
// off `window.__atelierInstallResponseHook`. The unit test loads this file the way
// Chrome injects it (readFileSync + new Function) and exercises `installResponseHook`,
// so there's a single source of truth.
//
// Read-only, best-effort: it must NEVER throw into the page or alter a response — a
// capture miss is acceptable, breaking the host site is not. Forwarding is deliberately
// STATUS-BLIND: a 4xx challenge body (Instagram `checkpoint_required`, a feed 429) is
// itself parseable JSON the driver needs to SEE so it can halt the sweep ([3A]); an
// `if (response.ok)` guard here would swallow exactly that signal.

/** How many recent responses to retain for replay (bounded so a long browse can't grow
 * it without limit). Overridable per-install via `bufferLimit`. */
var RESPONSE_HOOK_REPLAY_LIMIT = 25;

/**
 * Wrap `target.fetch` AND `target.XMLHttpRequest` so a response whose request URL
 * satisfies `isMatch(url)` is parsed and handed to `post({ url, json })`. Each forwarded
 * response is also BUFFERED (bounded to `bufferLimit`) and re-emitted when the target
 * receives a `message` whose `data.source === replaySource`.
 *
 * Idempotent (a flag on `target` prevents double-wrapping across repeated injections).
 * Returns true if it installed either interceptor, false if already installed, no
 * transport exists, or the required callbacks are missing. Both paths are
 * fire-and-forget and fully guarded — the page's own request is returned untouched, on
 * its original timing, and a parse failure is swallowed.
 *
 * @param opts.target       the scope to patch (production: `window`).
 * @param opts.post         `({ url, json }) => void` — receives each matched response.
 * @param opts.isMatch      `(url) => boolean` — the per-platform request-URL predicate.
 * @param opts.replaySource envelope `source` tag the controller posts to request a replay.
 * @param opts.bufferLimit  replay-buffer cap (default `RESPONSE_HOOK_REPLAY_LIMIT`).
 */
function installResponseHook(opts) {
  var options = opts || {};
  var scope = options.target || (typeof globalThis !== "undefined" ? globalThis : null);
  var post = options.post;
  var isMatch = options.isMatch;
  var replaySource = options.replaySource;
  var bufferLimit = options.bufferLimit == null ? RESPONSE_HOOK_REPLAY_LIMIT : options.bufferLimit;

  if (!scope) return false;
  if (typeof post !== "function" || typeof isMatch !== "function") return false;
  if (scope.__atelierResponseHookInstalled) return false;

  var installed = false;

  // Buffer every forwarded response (bounded) so the controller can REPLAY the pages the
  // site fetched before its sweep listener existed — otherwise a short/already-loaded
  // feed yields nothing. `forward` = remember + post.
  var recent = [];
  var forward = function (entry) {
    recent.push(entry);
    if (recent.length > bufferLimit) recent.shift();
    post(entry);
  };

  // Replay on request: re-emit the buffer (via `post`, not `forward`, so replaying can't
  // grow the buffer). Best-effort + guarded — never break the page.
  if (typeof scope.addEventListener === "function" && replaySource) {
    scope.addEventListener("message", function (event) {
      try {
        if (event && event.data && event.data.source === replaySource) {
          for (var i = 0; i < recent.length; i += 1) post(recent[i]);
        }
      } catch (_error) {
        /* never break the page */
      }
    });
  }

  // fetch path — a clone is parsed so the page still reads the original body. Status-blind
  // (see the file header): a 4xx body is forwarded too.
  if (typeof scope.fetch === "function") {
    var originalFetch = scope.fetch.bind(scope);
    scope.fetch = function () {
      var args = arguments;
      return originalFetch.apply(null, args).then(function (response) {
        try {
          var input = args[0];
          var url = typeof input === "string" ? input : (input && input.url) || "";
          if (isMatch(url) && response && typeof response.clone === "function") {
            response.clone().json().then(function (json) {
              forward({ url: url, json: json });
            }).catch(function () {});
          }
        } catch (_error) {
          /* never break the page */
        }
        return response;
      });
    };
    installed = true;
  }

  // XHR path — the live web client fetches feeds here. Stamp the URL at open(), then read
  // the response on `load` (a passive listener — never touches the page's own handlers or
  // the response). `load` fires on 4xx too, so a challenge body is forwarded.
  var XHR = scope.XMLHttpRequest;
  if (XHR && XHR.prototype && typeof XHR.prototype.open === "function") {
    var originalOpen = XHR.prototype.open;
    var originalSend = XHR.prototype.send;
    XHR.prototype.open = function (method, url) {
      try { this.__atelierResponseHookUrl = url; } catch (_error) { /* ignore */ }
      return originalOpen.apply(this, arguments);
    };
    XHR.prototype.send = function () {
      try {
        var url = this.__atelierResponseHookUrl;
        if (isMatch(url)) {
          this.addEventListener("load", function () {
            try {
              var type = this.responseType;
              var json = null;
              if (type === "" || type === "text") json = JSON.parse(this.responseText);
              else if (type === "json") json = this.response;
              if (json) forward({ url: url, json: json });
            } catch (_error) {
              /* ignore a non-JSON / unreadable body */
            }
          });
        }
      } catch (_error) {
        /* never break the page */
      }
      return originalSend.apply(this, arguments);
    };
    installed = true;
  }

  if (installed) scope.__atelierResponseHookInstalled = true;
  return installed;
}

// Publish the installer for the per-site hook injected AFTER this file (manifest order).
// A classic script's top-level `function` is already a MAIN-world global, but the
// explicit handle lets the site file DETECT a load-order mistake and fail loudly (see
// twitter-hook.js) instead of ReferenceError-ing into the page.
if (typeof window !== "undefined") {
  window.__atelierInstallResponseHook = installResponseHook;
}

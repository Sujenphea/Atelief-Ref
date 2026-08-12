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
//
// AUTH NEVER CROSSES A MESSAGE BOUNDARY ([090] 3A). `window.postMessage` is readable by
// EVERY script on the page, so the allowlisted request headers a follow-up call needs
// (X's bearer + csrf) are kept in THIS closure and never put in an envelope. A caller
// that needs a credentialled follow-up asks the hook to make it: the REQUEST PROXY below
// takes a URL, checks it against the install's `proxy.isAllowed` predicate, replays the
// stored headers onto a same-origin fetch, and posts back only the BODY. So the worst a
// hostile page script can get out of this seam is a response it could already fetch for
// itself with the session cookie it already has — never the token.

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
 * When `headerAllowlist` is set, the REQUEST headers whose (lowercased) names it
 * contains are REMEMBERED IN THIS CLOSURE — the credentials a platform needs to ask a
 * FOLLOW-UP question in the user's own session (X's thread expansion re-uses the
 * `authorization` / csrf pair the page just sent). Strictly an allowlist: an unlisted
 * header is never read, so this can't become an ambient header exfiltrator. The values
 * are never posted, never relayed to the service worker, never stored; the envelope
 * says only `hasAuth: true/false` so a listener can tell whether a follow-up is even
 * possible. To USE them, go through `opts.proxy`.
 *
 * `opts.proxy` turns the hook into a narrow request proxy: a message tagged
 * `proxy.requestSource` carrying `{ id, url }` is answered with a `proxy.replySource`
 * message carrying `{ id, status, json }` (or `{ id, error }`). `proxy.isAllowed(url)`
 * gates WHICH urls may be asked for, and is the whole security boundary — it must be as
 * narrow as the one follow-up the platform actually needs. No timeout is kept here: the
 * requester owns it (see hook-proxy.js), so a hung fetch strands nothing in the page.
 *
 * @param opts.target          the scope to patch (production: `window`).
 * @param opts.post            `({ url, json, hasAuth }) => void` — each matched response.
 * @param opts.isMatch         `(url) => boolean` — the per-platform request-URL predicate.
 * @param opts.replaySource    envelope `source` tag the controller posts to request a replay.
 * @param opts.bufferLimit     replay-buffer cap (default `RESPONSE_HOOK_REPLAY_LIMIT`).
 * @param opts.headerAllowlist array of lowercase request-header names to remember, or null.
 * @param opts.proxy           `{ requestSource, replySource, isAllowed }`, or null.
 */
function installResponseHook(opts) {
  var options = opts || {};
  var scope = options.target || (typeof globalThis !== "undefined" ? globalThis : null);
  var post = options.post;
  var isMatch = options.isMatch;
  var replaySource = options.replaySource;
  var bufferLimit = options.bufferLimit == null ? RESPONSE_HOOK_REPLAY_LIMIT : options.bufferLimit;
  var headerAllowlist = options.headerAllowlist || null;
  var proxy = options.proxy || null;

  // The credentials, MAIN-world only. Latest matched request wins — the page re-sends
  // them on every timeline call, so the freshest is the one still valid. NEVER posted.
  var authHeaders = null;

  /** Remember ONE header if the allowlist admits it. This is the single place a header
   * name is tested and lowercased and the single place a value is stored — both the
   * fetch path (a headers bag) and the XHR path (one `setRequestHeader` at a time)
   * funnel through it, so there is no second copy of the rule to drift ([090] 6A). */
  var rememberHeader = function (name, value) {
    if (!headerAllowlist || !name || value == null) return;
    var lower = String(name).toLowerCase();
    for (var i = 0; i < headerAllowlist.length; i += 1) {
      if (headerAllowlist[i] === lower) {
        if (!authHeaders) authHeaders = {};
        authHeaders[lower] = String(value);
        return;
      }
    }
  };

  /** Remember the allowlisted headers out of a fetch init / Request headers bag (a
   * `Headers`, a plain object, or an array of pairs — all three are legal and the client
   * uses more than one). Every name still goes through `rememberHeader`. */
  var rememberHeaders = function (source) {
    if (!headerAllowlist || !source) return;
    try {
      if (typeof source.forEach === "function" && typeof source.get === "function") {
        source.forEach(function (value, name) { rememberHeader(name, value); });   // Headers
      } else if (Array.isArray(source)) {
        for (var i = 0; i < source.length; i += 1) rememberHeader(source[i][0], source[i][1]);
      } else if (typeof source === "object") {
        for (var key in source) {
          if (Object.prototype.hasOwnProperty.call(source, key)) rememberHeader(key, source[key]);
        }
      }
    } catch (_error) {
      /* never break the page */
    }
  };

  if (!scope) return false;
  if (typeof post !== "function" || typeof isMatch !== "function") return false;
  if (scope.__atelierResponseHookInstalled) return false;

  var installed = false;
  var originalFetch = typeof scope.fetch === "function" ? scope.fetch.bind(scope) : null;

  // Buffer every forwarded response (bounded) so the controller can REPLAY the pages the
  // site fetched before its sweep listener existed — otherwise a short/already-loaded
  // feed yields nothing. `forward` = remember + post.
  //
  // `hasAuth` is a BOOLEAN, not the headers: a listener needs to know whether a
  // credentialled follow-up is possible, and that is all it needs to know. It is computed
  // at forward time (not replay time) so a replayed entry reports the state of the world
  // when the response was actually seen.
  var recent = [];
  var forward = function (entry) {
    entry.hasAuth = !!authHeaders;
    recent.push(entry);
    if (recent.length > bufferLimit) recent.shift();
    post(entry);
  };

  /** Answer a proxy request: one `{ id, url }` in, one `{ id, status, json }` or
   * `{ id, error }` out. Nothing but the BODY goes back — the headers that authorized it
   * stay here. */
  var serveProxyRequest = function (data) {
    var origin = (scope.location && scope.location.origin) || "*";
    var reply = function (payload) {
      payload.source = proxy.replySource;
      payload.id = data.id;
      try { scope.postMessage(payload, origin); } catch (_error) { /* never break the page */ }
    };
    // The security boundary. A page script can ask only for the one shape of follow-up
    // the platform declared — anything else is refused before a credential is touched.
    if (typeof data.url !== "string" || !proxy.isAllowed(data.url)) {
      reply({ error: "url-not-allowed" });
      return;
    }
    if (!authHeaders) { reply({ error: "no-credentials" }); return; }
    if (!originalFetch) { reply({ error: "no-fetch" }); return; }
    // The UNWRAPPED fetch: going through our own wrapper would re-enter the interception
    // path for a request we already know about.
    var headers = { "content-type": "application/json" };
    for (var name in authHeaders) {
      if (Object.prototype.hasOwnProperty.call(authHeaders, name)) headers[name] = authHeaders[name];
    }
    originalFetch(data.url, { method: "GET", headers: headers, credentials: "include" })
      .then(function (response) {
        var status = response && response.status;
        return response.json().then(
          function (json) { reply({ status: status, json: json }); },
          function () { reply({ status: status, json: null }); },   // a non-JSON error page
        );
      })
      .catch(function (error) { reply({ error: String(error) }); });
  };

  // One `message` listener for both inbound asks — replay and proxy. Best-effort +
  // guarded throughout: never break the page.
  if (typeof scope.addEventListener === "function" && (replaySource || proxy)) {
    scope.addEventListener("message", function (event) {
      try {
        var data = event && event.data;
        if (!data) return;
        // Replay: re-emit the buffer (via `post`, not `forward`, so replaying can't grow
        // the buffer or re-stamp `hasAuth`).
        if (replaySource && data.source === replaySource) {
          for (var i = 0; i < recent.length; i += 1) post(recent[i]);
          return;
        }
        if (proxy && data.source === proxy.requestSource) serveProxyRequest(data);
      } catch (_error) {
        /* never break the page */
      }
    });
  }

  // fetch path — a clone is parsed so the page still reads the original body. Status-blind
  // (see the file header): a 4xx body is forwarded too.
  if (originalFetch) {
    scope.fetch = function () {
      var args = arguments;
      var input = args[0];
      var requestUrl = typeof input === "string" ? input : (input && input.url) || "";
      try {
        // Headers ride the init OR a Request object — read both, so a client that builds
        // a `Request` is covered. Read at REQUEST time: the bag can be consumed by the
        // time the response lands.
        if (isMatch(requestUrl)) {
          rememberHeaders(input && input.headers);
          rememberHeaders(args[1] && args[1].headers);   // init wins — applied last
        }
      } catch (_error) {
        /* never break the page */
      }
      return originalFetch.apply(null, args).then(function (response) {
        try {
          if (isMatch(requestUrl) && response && typeof response.clone === "function") {
            response.clone().json().then(function (json) {
              forward({ url: requestUrl, json: json });
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
    var originalSetHeader = XHR.prototype.setRequestHeader;
    XHR.prototype.open = function (method, url) {
      try {
        this.__atelierResponseHookUrl = url;
      } catch (_error) { /* ignore */ }
      return originalOpen.apply(this, arguments);
    };
    // The live web client sets its auth headers here, one call at a time — the only
    // place they are observable on the XHR path. Same `rememberHeader` as the fetch path:
    // one allowlist rule, one store, no per-transport copy.
    if (typeof originalSetHeader === "function") {
      XHR.prototype.setRequestHeader = function (name, value) {
        try {
          if (isMatch(this.__atelierResponseHookUrl)) rememberHeader(name, value);
        } catch (_error) { /* never break the page */ }
        return originalSetHeader.apply(this, arguments);
      };
    }
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

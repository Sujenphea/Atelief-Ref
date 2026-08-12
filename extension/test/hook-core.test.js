// Atelier Capture — shared MAIN-world response-hook core tests ([5A][10A]).
//
// hook-core.js ships as a CLASSIC MAIN-world content script (NO export — a static
// export/import SyntaxErrors on injection and silently kills the hook). So we load +
// evaluate the REAL file the way Chrome injects it (readFileSync + new Function) and lift
// out `installResponseHook` — this tests the exact injected artifact, not an ESM shim.
//
// The matcher is INJECTED (`isMatch`), so these exercise the machinery independent of any
// platform: a request URL containing `/MATCH/` is forwarded, others pass through. The
// load-order pair tests at the bottom load hook-core + twitter-hook TOGETHER, in order,
// to pin the manifest's `["src/hook-core.js", "src/twitter-hook.js"]` contract.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const coreSrc = readFileSync(new URL("../src/hook-core.js", import.meta.url), "utf8");
const twitterHookSrc = readFileSync(new URL("../src/twitter-hook.js", import.meta.url), "utf8");

/** Load hook-core.js as Chrome would (classic script) and lift its functions out. A fake
 * `window` (an object) receives the published `__atelierInstallResponseHook`. */
function loadCore() {
  return new Function(
    "window",
    `${coreSrc}\nreturn { installResponseHook, RESPONSE_HOOK_REPLAY_LIMIT, published: window.__atelierInstallResponseHook };`,
  )({});
}
const { installResponseHook } = loadCore();

/** A URL matcher standing in for any platform's request predicate. */
const isMatch = (url) => typeof url === "string" && url.includes("/MATCH/");
const MATCH_URL = "https://host.example/api/MATCH/feed";
const OTHER_URL = "https://host.example/api/OTHER/feed";
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

// MARK: - syntax guard

test("hook-core.js is a valid CLASSIC script (no static export/import → injectable)", () => {
  assert.doesNotThrow(() => new Function("window", coreSrc));
});

test("loadCore publishes the installer on window (the per-site hook reads it there)", () => {
  const { published } = loadCore();
  assert.equal(typeof published, "function");
});

// MARK: - fetch path

/** A fake window scope with an injectable `fetch` returning a cloneable response. */
function fakeScope(responseJson, extra = {}) {
  const response = { clone: () => ({ json: async () => responseJson }), ...extra };
  return { fetch: async () => response, __response: response };
}

test("installResponseHook: forwards a matched fetch response, passes others through", async () => {
  const scope = fakeScope({ ok: 1 });
  const posted = [];
  assert.equal(installResponseHook({ target: scope, isMatch, post: (m) => posted.push(m) }), true);

  const returned = await scope.fetch(MATCH_URL);
  await tick();
  assert.equal(posted.length, 1);
  assert.equal(posted[0].url, MATCH_URL);
  assert.deepEqual(posted[0].json, { ok: 1 });
  assert.equal(returned, scope.__response);        // page's own response, untouched

  await scope.fetch(OTHER_URL);
  await tick();
  assert.equal(posted.length, 1);                  // non-matched request ignored
});

test("installResponseHook: forwards a 4xx body too (status-blind — the challenge signal, 3A)", async () => {
  // A challenge/429 body is parseable JSON the driver must SEE; an `if (response.ok)` guard
  // would swallow it. The fake response reports not-ok — it must forward anyway.
  const scope = fakeScope({ message: "checkpoint_required" }, { ok: false, status: 400 });
  const posted = [];
  installResponseHook({ target: scope, isMatch, post: (m) => posted.push(m) });
  await scope.fetch(MATCH_URL);
  await tick();
  assert.equal(posted.length, 1);
  assert.deepEqual(posted[0].json, { message: "checkpoint_required" });
});

test("installResponseHook: idempotent, and refuses without post/isMatch or a transport", () => {
  const scope = fakeScope({});
  assert.equal(installResponseHook({ target: scope, isMatch, post: () => {} }), true);
  assert.equal(installResponseHook({ target: scope, isMatch, post: () => {} }), false); // no double-wrap
  assert.equal(installResponseHook({ target: fakeScope({}), post: () => {} }), false);  // no isMatch
  assert.equal(installResponseHook({ target: fakeScope({}), isMatch }), false);         // no post
  assert.equal(installResponseHook({ target: {}, isMatch, post: () => {} }), false);    // no fetch, no XHR
});

test("installResponseHook: a post/parse failure never breaks the page's fetch", async () => {
  const scope = fakeScope({});
  const returned = await (() => {
    installResponseHook({ target: scope, isMatch, post: () => { throw new Error("boom"); } });
    return scope.fetch(MATCH_URL);
  })();
  await tick();
  assert.equal(returned, scope.__response);        // still returns cleanly
});

// MARK: - buffer + replay

/** A fake scope with an injectable fetch (settable json) AND a message-listener sink, so
 * we can drive both the interception and a replay request. */
function fakeReplayScope() {
  const messageListeners = [];
  let nextJson = null;
  return {
    fetch: async () => ({ clone: () => ({ json: async () => nextJson }) }),
    setJson: (j) => { nextJson = j; },
    addEventListener: (type, fn) => { if (type === "message") messageListeners.push(fn); },
    dispatch: (data) => { for (const fn of messageListeners) fn({ data }); },
  };
}
const REPLAY_SOURCE = "atelier-test-replay";

test("installResponseHook: buffers forwarded responses and replays them on request", async () => {
  const scope = fakeReplayScope();
  const posted = [];
  installResponseHook({ target: scope, isMatch, replaySource: REPLAY_SOURCE, post: (m) => posted.push(m) });

  scope.setJson({ page: 1 }); await scope.fetch(MATCH_URL); await tick();
  scope.setJson({ page: 2 }); await scope.fetch(MATCH_URL); await tick();
  assert.equal(posted.length, 2, "two live forwards");

  // A late subscriber asks for a replay → both buffered pages re-emit, in order.
  scope.dispatch({ source: REPLAY_SOURCE });
  assert.deepEqual(posted.slice(2).map((p) => p.json), [{ page: 1 }, { page: 2 }]);

  scope.dispatch({ source: "something-else" });   // unrelated message → no replay
  assert.equal(posted.length, 4);
});

test("installResponseHook: the replay buffer is bounded (keeps only the most recent)", async () => {
  const scope = fakeReplayScope();
  const posted = [];
  installResponseHook({
    target: scope, isMatch, replaySource: REPLAY_SOURCE, bufferLimit: 25, post: (m) => posted.push(m),
  });

  const N = 30; // exceeds the buffer limit (25)
  for (let i = 0; i < N; i += 1) { scope.setJson({ page: i }); await scope.fetch(MATCH_URL); await tick(); }

  const before = posted.length;
  scope.dispatch({ source: REPLAY_SOURCE });
  const replayed = posted.slice(before).map((p) => p.json.page);
  assert.ok(replayed.length < N, "buffer is bounded, not unbounded");
  assert.equal(replayed[replayed.length - 1], N - 1, "keeps the most recent page");
  assert.equal(replayed[0], N - replayed.length, "drops the oldest pages");
});

// MARK: - XHR path

/** A fake scope whose XMLHttpRequest fires a synchronous `load` on send(), with a
 * settable responseText / responseType — mirrors how a live client pulls a feed. */
function fakeXHRScope() {
  class FakeXHR {
    constructor() { this._load = []; this.responseType = ""; }
    open(method, url) { this._method = method; this._url = url; }
    addEventListener(type, fn) { if (type === "load") this._load.push(fn); }
    send() { for (const fn of this._load) fn.call(this); } // synchronous load
  }
  return { XMLHttpRequest: FakeXHR };
}

test("installResponseHook: forwards a matched XHR response, ignores non-matched XHRs", () => {
  const scope = fakeXHRScope();
  const posted = [];
  assert.equal(installResponseHook({ target: scope, isMatch, post: (m) => posted.push(m) }), true);

  const xhr = new scope.XMLHttpRequest();
  xhr.open("GET", MATCH_URL);
  xhr.responseText = JSON.stringify({ ok: 2 });
  xhr.send();
  assert.equal(posted.length, 1);
  assert.equal(posted[0].url, MATCH_URL);
  assert.deepEqual(posted[0].json, { ok: 2 });

  const other = new scope.XMLHttpRequest();
  other.open("GET", OTHER_URL);
  other.responseText = JSON.stringify({ ok: 3 });
  other.send();
  assert.equal(posted.length, 1);                  // non-matched XHR ignored
});

test("installResponseHook: XHR responseType 'json' reads the parsed response object", () => {
  const scope = fakeXHRScope();
  const posted = [];
  installResponseHook({ target: scope, isMatch, post: (m) => posted.push(m) });

  const xhr = new scope.XMLHttpRequest();
  xhr.open("GET", MATCH_URL);
  xhr.responseType = "json";
  xhr.response = { already: "parsed" };
  xhr.send();
  assert.deepEqual(posted[0].json, { already: "parsed" });
});

test("installResponseHook: an unparseable XHR body is swallowed (page unaffected)", () => {
  const scope = fakeXHRScope();
  installResponseHook({ target: scope, isMatch, post: () => { throw new Error("boom"); } });

  const xhr = new scope.XMLHttpRequest();
  xhr.open("GET", MATCH_URL);
  xhr.responseText = "<html>not json</html>";
  assert.doesNotThrow(() => xhr.send());           // load handler never throws into send
});

// MARK: - request-header forwarding (the credentials a follow-up request needs)

const ALLOWLIST = ["authorization", "x-csrf-token"];

test("installResponseHook: forwards ONLY allowlisted fetch request headers", async () => {
  const scope = fakeScope({ ok: 1 });
  const posted = [];
  installResponseHook({
    target: scope, isMatch, post: (m) => posted.push(m), headerAllowlist: ALLOWLIST,
  });

  await scope.fetch(MATCH_URL, { headers: {
    Authorization: "Bearer abc",            // case-insensitive → lowercased
    "x-csrf-token": "csrf123",
    cookie: "secret=1",                     // NOT on the list — must never be read
    "x-client-transaction-id": "per-request",
  } });
  await tick();
  assert.deepEqual(posted[0].headers, { authorization: "Bearer abc", "x-csrf-token": "csrf123" });
});

test("installResponseHook: reads fetch headers from a Headers object or a pair array", async () => {
  for (const headers of [
    new Map([["authorization", "Bearer h"]]),        // Headers-like: forEach + get
    [["authorization", "Bearer h"], ["cookie", "no"]],
  ]) {
    const scope = fakeScope({ ok: 1 });
    const posted = [];
    installResponseHook({
      target: scope, isMatch, post: (m) => posted.push(m), headerAllowlist: ALLOWLIST,
    });
    await scope.fetch(MATCH_URL, { headers });
    await tick();
    assert.deepEqual(posted[0].headers, { authorization: "Bearer h" });
  }
});

test("installResponseHook: with NO allowlist, headers are never read at all", async () => {
  const scope = fakeScope({ ok: 1 });
  const posted = [];
  installResponseHook({ target: scope, isMatch, post: (m) => posted.push(m) });
  await scope.fetch(MATCH_URL, { headers: { authorization: "Bearer abc" } });
  await tick();
  assert.equal(posted[0].headers, null);   // opt-in only — no ambient header capture
});

/** A FakeXHR that also records setRequestHeader, which the live client uses. */
function fakeXHRScopeWithHeaders() {
  class FakeXHR {
    constructor() { this._load = []; this.responseType = ""; }
    open(method, url) { this._method = method; this._url = url; }
    setRequestHeader() {}
    addEventListener(type, fn) { if (type === "load") this._load.push(fn); }
    send() { for (const fn of this._load) fn.call(this); }
  }
  return { XMLHttpRequest: FakeXHR };
}

test("installResponseHook: forwards allowlisted XHR headers, scoped to a matched url", () => {
  const scope = fakeXHRScopeWithHeaders();
  const posted = [];
  installResponseHook({
    target: scope, isMatch, post: (m) => posted.push(m), headerAllowlist: ALLOWLIST,
  });

  const xhr = new scope.XMLHttpRequest();
  xhr.open("GET", MATCH_URL);
  xhr.setRequestHeader("authorization", "Bearer xhr");
  xhr.setRequestHeader("cookie", "secret=1");        // unlisted → not captured
  xhr.responseText = JSON.stringify({ ok: 2 });
  xhr.send();
  assert.deepEqual(posted[0].headers, { authorization: "Bearer xhr" });

  // Headers set on a NON-matched request are not captured either.
  const other = new scope.XMLHttpRequest();
  other.open("GET", OTHER_URL);
  other.setRequestHeader("authorization", "Bearer other");
  other.responseText = JSON.stringify({ ok: 3 });
  other.send();
  assert.equal(posted.length, 1);
});

test("installResponseHook: a REUSED xhr does not leak the previous request's headers", () => {
  const scope = fakeXHRScopeWithHeaders();
  const posted = [];
  installResponseHook({
    target: scope, isMatch, post: (m) => posted.push(m), headerAllowlist: ALLOWLIST,
  });

  const xhr = new scope.XMLHttpRequest();
  xhr.open("GET", MATCH_URL);
  xhr.setRequestHeader("authorization", "Bearer first");
  xhr.responseText = JSON.stringify({ ok: 1 });
  xhr.send();

  xhr.open("GET", MATCH_URL);                        // re-opened, no headers set this time
  xhr.responseText = JSON.stringify({ ok: 2 });
  xhr.send();
  // `open()` clears the stash, so the second request forwards no headers rather than
  // the first request's. (A re-sent xhr keeps its listeners — real XHR semantics too —
  // so the earlier send's handler also refires; the LAST post is the new request's.)
  assert.equal(posted.at(-1).headers, null);
});

// MARK: - load-order pairing (the manifest contract: hook-core BEFORE the site hook)

/** A fake window a site hook auto-installs onto: a matching hostname + a cloneable fetch
 * + a message sink. */
function fakeSiteWindow(hostname) {
  const listeners = [];
  return {
    location: { hostname, origin: `https://${hostname}` },
    fetch: async () => ({ clone: () => ({ json: async () => ({}) }) }),
    addEventListener: (type, fn) => { if (type === "message") listeners.push(fn); },
    postMessage: () => {},
  };
}

test("load order [hook-core, twitter-hook]: core first → the site hook installs", () => {
  const win = fakeSiteWindow("x.com");
  new Function("window", coreSrc)(win);                          // core publishes the installer
  assert.equal(typeof win.__atelierInstallResponseHook, "function");
  new Function("window", "console", twitterHookSrc)(win, console); // site auto-installs
  assert.equal(win.__atelierResponseHookInstalled, true);
});

test("wrong order (site hook without core) fails LOUDLY but never throws into the page", () => {
  const win = fakeSiteWindow("x.com");                            // no core loaded → installer absent
  const errors = [];
  const spyConsole = { error: (...a) => errors.push(a.join(" ")) };
  assert.doesNotThrow(() => new Function("window", "console", twitterHookSrc)(win, spyConsole));
  assert.equal(win.__atelierResponseHookInstalled, undefined);   // did NOT install
  assert.equal(errors.length, 1);                                // failed loudly
  assert.match(errors[0], /hook-core\.js must load before/);
});

test("the site hook is inert on a non-matching host (no install, no error)", () => {
  const win = fakeSiteWindow("example.com");
  new Function("window", coreSrc)(win);
  const errors = [];
  new Function("window", "console", twitterHookSrc)(win, { error: (...a) => errors.push(a) });
  assert.equal(win.__atelierResponseHookInstalled, undefined);   // not an X host → skipped
  assert.equal(errors.length, 0);
});

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

/** The body half of a fake `Response.clone()` — both accessors the real one has. */
const cloneable = (json) => ({
  json: async () => json,
  text: async () => JSON.stringify(json),
});

/** A fake window scope with an injectable `fetch` returning a cloneable response. */
function fakeScope(responseJson, extra = {}) {
  // A real `Response.clone()` exposes BOTH `json()` and `text()`; the hook reads text so
  // it can size the replay buffer (098 R15). Model both or the fake diverges from the
  // browser in a way that hides a working code path.
  const response = { clone: () => cloneable(responseJson), ...extra };
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
    fetch: async () => ({ clone: () => cloneable(nextJson) }),
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

test("installResponseHook: the replay buffer is bounded by SIZE, not only by count (098 R15)", async () => {
  const posted = [];
  const scope = fakeReplayScope();
  // Room for 25 entries by count, but only ~3 of these by size — so the size bound is
  // what bites. A count-only bound is why 25 X timeline pages (~871 KB each) could sit
  // in the MAIN world for the life of a tab.
  const big = "x".repeat(1000);
  installResponseHook({
    target: scope, isMatch, replaySource: REPLAY_SOURCE, bufferLimit: 25, byteLimit: 3500,
    post: (m) => posted.push(m),
  });
  for (let i = 0; i < 10; i += 1) {
    scope.setJson({ page: i, pad: big });
    await scope.fetch(MATCH_URL);
    await tick();
  }

  const before = posted.length;
  scope.dispatch({ source: REPLAY_SOURCE });
  const replayed = posted.slice(before).map((p) => p.json.page);
  assert.ok(replayed.length < 10, "the size bound evicted, though the count bound had room");
  assert.equal(replayed[replayed.length - 1], 9, "the most recent page is always kept");
  assert.equal(replayed[0], 10 - replayed.length, "oldest first out");
});

test("installResponseHook: a single page larger than the whole budget is still replayable", async () => {
  const posted = [];
  const scope = fakeReplayScope();
  installResponseHook({
    target: scope, isMatch, replaySource: REPLAY_SOURCE, byteLimit: 10,
    post: (m) => posted.push(m),
  });
  // The cap exists to stop ACCUMULATION. Evicting the only entry would mean a sweep on a
  // feed with one big page replays nothing and stalls — worse than the memory it saves.
  scope.setJson({ page: 0, pad: "y".repeat(5000) });
  await scope.fetch(MATCH_URL);
  await tick();

  const before = posted.length;
  scope.dispatch({ source: REPLAY_SOURCE });
  assert.deepEqual(posted.slice(before).map((p) => p.json.page), [0]);
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

// MARK: - credentials NEVER cross a message boundary ([090] 3A/10A)
//
// The load-bearing security property of the whole hook. `window.postMessage` is readable
// by every script on the page, so the invariant is absolute and asserted the blunt way:
// serialize what the hook emits and grep it for the secret. That catches a leak through
// ANY field — a rename, a debug key, a nested echo — which a `deepEqual` on one expected
// property would not.

const ALLOWLIST = ["authorization", "x-csrf-token"];
const SECRETS = ["Bearer super-secret", "csrf-secret", "session=cookie-secret", "txn-secret"];

/** Every value the hook emitted, as one string — what a page script could read. */
const emitted = (posted) => JSON.stringify(posted);

/** The full header bag a live X client sends: two allowlisted, two that must never be
 * touched at all (`cookie` is the session; `x-client-transaction-id` is per-request). */
const LIVE_HEADERS = {
  Authorization: SECRETS[0],                 // case-insensitive → lowercased internally
  "x-csrf-token": SECRETS[1],
  cookie: SECRETS[2],
  "x-client-transaction-id": SECRETS[3],
};

test("installResponseHook: no request header value EVER appears in a forwarded payload", async () => {
  const scope = fakeScope({ ok: 1 });
  const posted = [];
  installResponseHook({
    target: scope, isMatch, post: (m) => posted.push(m), headerAllowlist: ALLOWLIST,
  });

  await scope.fetch(MATCH_URL, { headers: LIVE_HEADERS });
  await tick();

  assert.equal(posted.length, 1);
  for (const secret of SECRETS) {
    assert.ok(!emitted(posted).includes(secret),
      `"${secret}" crossed the message boundary — auth must stay in the MAIN world`);
  }
  assert.equal("headers" in posted[0], false, "no headers field survives on the envelope");
  // What DOES cross is the one bit a listener needs: whether a follow-up is possible.
  assert.equal(posted[0].hasAuth, true);
});

test("installResponseHook: hasAuth is false until an allowlisted header is actually seen", async () => {
  const scope = fakeScope({ ok: 1 });
  const posted = [];
  installResponseHook({
    target: scope, isMatch, post: (m) => posted.push(m), headerAllowlist: ALLOWLIST,
  });
  await scope.fetch(MATCH_URL, { headers: { cookie: SECRETS[2] } });  // nothing allowlisted
  await tick();
  assert.equal(posted[0].hasAuth, false);
});

test("installResponseHook: with NO allowlist, headers are never read at all", async () => {
  const scope = fakeScope({ ok: 1 });
  const posted = [];
  installResponseHook({ target: scope, isMatch, post: (m) => posted.push(m) });
  await scope.fetch(MATCH_URL, { headers: LIVE_HEADERS });
  await tick();
  assert.equal(posted[0].hasAuth, false);   // opt-in only — no ambient header capture
  for (const secret of SECRETS) assert.ok(!emitted(posted).includes(secret));
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

test("installResponseHook: the XHR path leaks no header value either", () => {
  const scope = fakeXHRScopeWithHeaders();
  const posted = [];
  installResponseHook({
    target: scope, isMatch, post: (m) => posted.push(m), headerAllowlist: ALLOWLIST,
  });

  const xhr = new scope.XMLHttpRequest();
  xhr.open("GET", MATCH_URL);
  for (const [name, value] of Object.entries(LIVE_HEADERS)) xhr.setRequestHeader(name, value);
  xhr.responseText = JSON.stringify({ ok: 2 });
  xhr.send();

  assert.equal(posted.length, 1);
  assert.equal(posted[0].hasAuth, true);
  for (const secret of SECRETS) assert.ok(!emitted(posted).includes(secret));
});

test("installResponseHook: headers on a NON-matched request are never remembered", () => {
  const scope = fakeXHRScopeWithHeaders();
  const posted = [];
  installResponseHook({
    target: scope, isMatch, post: (m) => posted.push(m), headerAllowlist: ALLOWLIST,
  });

  const other = new scope.XMLHttpRequest();
  other.open("GET", OTHER_URL);                      // outside the platform's matcher
  other.setRequestHeader("authorization", SECRETS[0]);
  other.responseText = JSON.stringify({ ok: 3 });
  other.send();
  assert.equal(posted.length, 0);                    // not forwarded at all

  const matched = new scope.XMLHttpRequest();
  matched.open("GET", MATCH_URL);                    // no headers set on THIS one
  matched.responseText = JSON.stringify({ ok: 4 });
  matched.send();
  // The unmatched request's authorization was never stored, so there is nothing to claim.
  assert.equal(posted[0].hasAuth, false);
});

// MARK: - the request proxy (the credentialled follow-up, 3A)

/** A scope that can run the proxy: a message sink to receive requests, a `postMessage`
 * that records replies, a location for the target origin, and a recording fetch. */
function fakeProxyScope({ status = 200, json = { conversation: true } } = {}) {
  const listeners = [];
  const scope = {
    location: { origin: "https://host.example" },
    fetchCalls: [],
    replies: [],
    failNext: null,                    // settable mid-test: fail the PROXIED call only
    fetch: async (url, init) => {
      scope.fetchCalls.push({ url, init });
      if (scope.failNext) throw new Error(scope.failNext);
      return { status, json: async () => json, clone: () => cloneable(json) };
    },
    addEventListener: (type, fn) => { if (type === "message") listeners.push(fn); },
    postMessage: (data) => scope.replies.push(data),
    dispatch: (data) => { for (const fn of listeners) fn({ data }); },
  };
  return scope;
}

const PROXY = { requestSource: "req", replySource: "rep" };
const ALLOWED_URL = "https://host.example/i/api/graphql/QID/TweetDetail?x=1";
const proxyWith = (scope, isAllowed = (url) => url === ALLOWED_URL, post = () => {}) =>
  installResponseHook({
    target: scope, isMatch, post, headerAllowlist: ALLOWLIST,
    proxy: { ...PROXY, isAllowed },
  });

/** Prime the hook with the page's credentials the way a real timeline request would. */
async function primeAuth(scope) {
  await scope.fetch(MATCH_URL, { headers: LIVE_HEADERS });
  await tick();
}

test("proxy: replays the stored auth onto the request and returns only the body", async () => {
  const scope = fakeProxyScope();
  proxyWith(scope);
  await primeAuth(scope);
  scope.fetchCalls.length = 0;

  scope.dispatch({ source: "req", id: "c1", url: ALLOWED_URL });
  await tick();

  // The request the hook made DOES carry the credentials — that is the point of it.
  assert.equal(scope.fetchCalls.length, 1);
  const { url, init } = scope.fetchCalls[0];
  assert.equal(url, ALLOWED_URL);
  assert.equal(init.credentials, "include");
  assert.equal(init.method, "GET");
  assert.equal(init.headers.authorization, SECRETS[0]);
  assert.equal(init.headers["x-csrf-token"], SECRETS[1]);
  assert.equal(init.headers.cookie, undefined, "an unlisted header is not replayed either");

  // The REPLY carries the body and the correlation id — and no credential.
  assert.equal(scope.replies.length, 1);
  assert.deepEqual(scope.replies[0], {
    source: "rep", id: "c1", status: 200, json: { conversation: true },
  });
  for (const secret of SECRETS) assert.ok(!JSON.stringify(scope.replies).includes(secret));
});

test("proxy: refuses a url outside the platform's allowlist, without touching credentials", async () => {
  const scope = fakeProxyScope();
  proxyWith(scope);
  await primeAuth(scope);
  scope.fetchCalls.length = 0;

  // The attack this gate exists for: a page script asking the hook to spend the user's
  // token on an endpoint of its choosing and hand back the answer.
  for (const url of [
    "https://host.example/i/api/1.1/dm/inbox.json",       // same origin, wrong endpoint
    "https://evil.example/i/api/graphql/Q/TweetDetail",   // right shape, wrong origin
    null,
    { toString: () => ALLOWED_URL },                      // not a string
  ]) {
    scope.dispatch({ source: "req", id: "x", url });
  }
  await tick();

  assert.equal(scope.fetchCalls.length, 0, "no request was made at all");
  assert.equal(scope.replies.length, 4);
  for (const reply of scope.replies) assert.equal(reply.error, "url-not-allowed");
});

test("proxy: says so rather than guessing when it has no credentials yet", async () => {
  const scope = fakeProxyScope();
  proxyWith(scope);                                  // no timeline request seen → nothing stored
  scope.dispatch({ source: "req", id: "c1", url: ALLOWED_URL });
  await tick();
  assert.equal(scope.fetchCalls.length, 0);
  assert.equal(scope.replies[0].error, "no-credentials");
});

test("proxy: a fetch throw comes back as an error reply, never as a hang or a page throw", async () => {
  const scope = fakeProxyScope();
  proxyWith(scope);
  await primeAuth(scope);
  scope.failNext = "network down";           // the proxied call is the one that fails

  assert.doesNotThrow(() => scope.dispatch({ source: "req", id: "c1", url: ALLOWED_URL }));
  await tick();
  assert.match(scope.replies.at(-1).error, /network down/);
  assert.equal(scope.replies.at(-1).id, "c1", "an error still carries its correlation id");
});

test("proxy: a 4xx body still comes back (the caller reads the status to repair features)", async () => {
  const scope = fakeProxyScope({
    status: 400, json: { errors: [{ message: "The following features cannot be null: f" }] },
  });
  proxyWith(scope, () => true);
  await primeAuth(scope);
  scope.dispatch({ source: "req", id: "c1", url: ALLOWED_URL });
  await tick();
  assert.equal(scope.replies[0].status, 400);
  assert.deepEqual(scope.replies[0].json.errors[0].message,
    "The following features cannot be null: f");
});

test("proxy: an unrelated message is not a proxy request (and a replay is not either)", async () => {
  const scope = fakeProxyScope();
  installResponseHook({
    target: scope, isMatch, post: () => {}, headerAllowlist: ALLOWLIST,
    replaySource: REPLAY_SOURCE, proxy: { ...PROXY, isAllowed: () => true },
  });
  await primeAuth(scope);
  scope.fetchCalls.length = 0;
  scope.replies.length = 0;

  scope.dispatch({ source: "something-else", url: ALLOWED_URL });
  scope.dispatch({ source: REPLAY_SOURCE });
  await tick();
  assert.equal(scope.fetchCalls.length, 0);
  assert.equal(scope.replies.length, 0);
});

// MARK: - load-order pairing (the manifest contract: hook-core BEFORE the site hook)

/** A fake window a site hook auto-installs onto: a matching hostname + a cloneable fetch
 * + a message sink. */
function fakeSiteWindow(hostname) {
  const listeners = [];
  return {
    location: { hostname, origin: `https://${hostname}` },
    fetch: async () => ({ clone: () => cloneable({}) }),
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

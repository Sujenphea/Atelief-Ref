// Atelier Capture — hook-proxy (the ISOLATED-world end of the request proxy, [090] 3A/10A).
//
// The client's whole job is to make a message round-trip look like a fetch, so these pin
// the three things that can go wrong at a message boundary: a reply landing against the
// WRONG request, a reply that never comes, and a listener outliving its sweep. The
// security assertion lives here too, from this side: what the controller SENDS carries no
// credential either — the proxy is a url and an id, nothing more.

import { test } from "node:test";
import assert from "node:assert/strict";

import { createHookProxyFetch, HookProxyError, HOOK_PROXY_TIMEOUT_MS } from "../src/hook-proxy.js";
import { HOOK_PROXY_REQUEST_SOURCE, HOOK_PROXY_REPLY_SOURCE } from "../src/bulk-messages.js";

/** A fake window: records what the controller posts, and lets a test play the hook's
 * reply back through the listener the client registered. Timers are injected so a
 * timeout test doesn't take 20 seconds. */
function fakeWindow() {
  const listeners = [];
  const timers = new Map();
  let nextTimer = 0;
  const win = {
    location: { origin: "https://x.com" },
    posted: [],
    postMessage: (data) => win.posted.push(data),
    addEventListener: (type, fn) => { if (type === "message") listeners.push(fn); },
    removeEventListener: (type, fn) => {
      const i = listeners.indexOf(fn);
      if (i >= 0) listeners.splice(i, 1);
    },
    listenerCount: () => listeners.length,
    // Deliver a message as the window would — from this same window.
    deliver: (data, source = win) => { for (const fn of [...listeners]) fn({ source, data }); },
    setTimer: (fn, ms) => { nextTimer += 1; timers.set(nextTimer, { fn, ms }); return nextTimer; },
    clearTimer: (handle) => timers.delete(handle),
    fireTimers: () => { for (const { fn } of [...timers.values()]) fn(); },
    pendingTimers: () => timers.size,
  };
  return win;
}

const proxyFor = (win) => createHookProxyFetch({
  win, setTimer: win.setTimer, clearTimer: win.clearTimer, random: () => 0.5,
});

/** The hook's answer to the Nth request the controller posted. */
const replyTo = (win, index, payload) =>
  win.deliver({ source: HOOK_PROXY_REPLY_SOURCE, id: win.posted[index].id, ...payload });

const URL_A = "https://x.com/i/api/graphql/QID/TweetDetail?variables=%7B%7D";
const URL_B = "https://x.com/i/api/graphql/QID/TweetDetail?variables=%7B%22b%22%3A1%7D";

test("proxyFetch: posts a url + correlation id and resolves with the answered body", async () => {
  const win = fakeWindow();
  const { proxyFetch } = proxyFor(win);

  const inFlight = proxyFetch(URL_A);
  assert.equal(win.posted.length, 1);
  assert.equal(win.posted[0].source, HOOK_PROXY_REQUEST_SOURCE);
  assert.equal(win.posted[0].url, URL_A);
  assert.ok(win.posted[0].id, "every request carries a correlation id");
  // What goes OUT is a url and an id — nothing that could authorize anything.
  assert.deepEqual(Object.keys(win.posted[0]).sort(), ["id", "source", "url"]);

  replyTo(win, 0, { status: 200, json: { data: 1 } });
  const response = await inFlight;
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { data: 1 });
});

test("proxyFetch: concurrent requests settle against their OWN reply, in any order", async () => {
  const win = fakeWindow();
  const { proxyFetch } = proxyFor(win);

  const first = proxyFetch(URL_A);
  const second = proxyFetch(URL_B);
  assert.notEqual(win.posted[0].id, win.posted[1].id, "ids are distinct");

  // Answered out of order — the id is what pairs them, not arrival.
  replyTo(win, 1, { status: 200, json: { which: "second" } });
  replyTo(win, 0, { status: 200, json: { which: "first" } });

  assert.deepEqual(await (await first).json(), { which: "first" });
  assert.deepEqual(await (await second).json(), { which: "second" });
});

test("proxyFetch: an unknown, duplicate or foreign-window reply is ignored", async () => {
  const win = fakeWindow();
  const { proxyFetch } = proxyFor(win);
  const inFlight = proxyFetch(URL_A);
  const { id } = win.posted[0];

  win.deliver({ source: HOOK_PROXY_REPLY_SOURCE, id: "not-ours", status: 200, json: { bad: 1 } });
  win.deliver({ source: "some-other-extension", id, status: 200, json: { bad: 2 } });
  // A reply from an IFRAME's window is not this hook's answer.
  win.deliver({ source: HOOK_PROXY_REPLY_SOURCE, id, status: 200, json: { bad: 3 } }, {});

  replyTo(win, 0, { status: 200, json: { good: 1 } });
  assert.deepEqual(await (await inFlight).json(), { good: 1 });

  // A second answer to a settled id is dropped rather than resolving anything twice.
  assert.doesNotThrow(() => replyTo(win, 0, { status: 200, json: { late: 1 } }));
});

test("proxyFetch: an error reply rejects as a typed HookProxyError", async () => {
  const win = fakeWindow();
  const { proxyFetch } = proxyFor(win);
  const inFlight = proxyFetch(URL_A);
  replyTo(win, 0, { error: "url-not-allowed" });
  await assert.rejects(inFlight, (error) => {
    assert.ok(error instanceof HookProxyError);
    assert.equal(error.reason, "url-not-allowed");
    return true;
  });
});

test("proxyFetch: a reply that never comes times out instead of stranding the sweep", async () => {
  const win = fakeWindow();
  const { proxyFetch } = proxyFor(win);
  const inFlight = proxyFetch(URL_A);
  assert.equal(win.pendingTimers(), 1);

  win.fireTimers();                                     // the hook never answered
  await assert.rejects(inFlight, (error) => error.reason === "timeout");
  // A late answer after the timeout resolves nothing (the id is already gone).
  assert.doesNotThrow(() => replyTo(win, 0, { status: 200, json: {} }));
});

test("proxyFetch: a settled request leaves no timer behind", async () => {
  const win = fakeWindow();
  const { proxyFetch } = proxyFor(win);
  const inFlight = proxyFetch(URL_A);
  replyTo(win, 0, { status: 200, json: {} });
  await inFlight;
  assert.equal(win.pendingTimers(), 0, "the timeout is cleared on a normal answer");
});

test("dispose: removes the listener and rejects everything still in flight", async () => {
  const win = fakeWindow();
  const { proxyFetch, dispose } = proxyFor(win);
  assert.equal(win.listenerCount(), 1);

  const inFlight = proxyFetch(URL_A);
  dispose();

  assert.equal(win.listenerCount(), 0, "no listener survives the sweep");
  assert.equal(win.pendingTimers(), 0);
  await assert.rejects(inFlight, (error) => error.reason === "disposed");
});

test("proxyFetch: a postMessage that throws rejects rather than hanging", async () => {
  const win = fakeWindow();
  win.postMessage = () => { throw new Error("page gone"); };
  const { proxyFetch } = proxyFor(win);
  await assert.rejects(proxyFetch(URL_A), (error) => /page gone/.test(error.message));
  assert.equal(win.pendingTimers(), 0);
});

test("the default timeout is generous enough for a real round-trip", () => {
  // A thread that fails to expand costs one unexpanded post; a timeout that fires under
  // a slow network costs every thread in the sweep. The bias is deliberate.
  assert.ok(HOOK_PROXY_TIMEOUT_MS >= 10_000);
});

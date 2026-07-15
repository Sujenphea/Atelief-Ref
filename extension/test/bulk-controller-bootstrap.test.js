// Atelier Capture — controller bootstrap tests (decision 9A).
//
// registerBulkController is the chrome.*/window glue that turns a START runtime message
// into a running sweep. It was previously E2E-only; these fakes (a `chromeApi` whose
// sendMessage answers the bulk protocol, a `win` whose fetch returns an empty board
// feed) drive the whole bootstrap under `node --test` with no browser and no timers.
// Pinned: a START dispatches a real sweep and replies ok; a non-START is ignored so
// other handlers run; re-registration is idempotent (one listener); a transport error
// surfaces as an ok:false reply instead of an unhandled rejection.

import { test } from "node:test";
import assert from "node:assert/strict";

import { registerBulkController } from "../src/bulk-controller.js";
import {
  BULK, START, buildStartMessage, TIMELINE_MESSAGE_SOURCE as MSG_SRC,
} from "../src/bulk-messages.js";

/** A fake `chromeApi`: records added listeners + sent messages, answers the bulk
 * protocol, and backs storage with a plain object. `openReply` overrides the open
 * answer so a test can inject a transport error (an `{ __error }` envelope). */
function fakeChromeApi({ openReply = { jobId: "JOB-1", caps: null }, boardFeed } = {}) {
  const listeners = [];
  const store = {};
  const sent = [];
  return {
    listeners, store, sent,
    runtime: {
      onMessage: { addListener: (fn) => listeners.push(fn) },
      sendMessage: async (message) => {
        sent.push(message);
        switch (message.type) {
          case BULK.open: return openReply;
          case BULK.known: return [];
          case BULK.relay: return { status: "saved", deduplicated: false };
          case BULK.complete: return true;
          default: return null;
        }
      },
    },
    storage: {
      local: {
        async get(key) { return key in store ? { [key]: store[key] } : {}; },
        async set(obj) { Object.assign(store, obj); },
        async remove(key) { delete store[key]; },
      },
    },
  };
}

/** A fake Pinterest page whose `fetch` returns a single empty (`-end-`) board-feed
 * page, so the real Pinterest driver enumerates zero pins and the sweep completes
 * immediately — no pacing timers, but the full driver-build wiring is exercised. */
function fakePinterestWin() {
  const fetchCalls = [];
  const win = {
    location: { host: "www.pinterest.com", origin: "https://www.pinterest.com" },
    document: {
      documentElement: { innerHTML: 'window.__PWS_DATA__={"app_version":"a1b2c3"}' },
      cookie: "csrftoken=tok123; other=x",
    },
    fetch: async (url) => {
      fetchCalls.push(url);
      return {
        ok: true,
        json: async () => ({
          resource_response: { status: "success", http_status: 200, data: [], bookmark: "-end-" },
        }),
      };
    },
    addEventListener() {},
    postMessage() {},
  };
  return { win, fetchCalls };
}

/** Invoke the one registered listener; resolve with the reply sendResponse receives
 * (or undefined if the listener declines the message). Also returns the listener's
 * own return value (`true` = async reply pending, `false` = not handled). */
function dispatch(chromeApi, message) {
  const listener = chromeApi.listeners[0];
  return new Promise((resolve) => {
    let returned;
    returned = listener(message, {}, (reply) => resolve({ reply, returned }));
    if (returned !== true) resolve({ reply: undefined, returned });
  });
}

const PIN_SPEC = { platform: "pinterest", input: { boardId: "B", boardUrl: "/u/b/" }, scope: "board:x" };

test("registerBulkController: a START message drives a real sweep and replies ok", async () => {
  const chromeApi = fakeChromeApi();
  const { win, fetchCalls } = fakePinterestWin();
  registerBulkController(win, chromeApi);

  const { reply, returned } = await dispatch(chromeApi, buildStartMessage(PIN_SPEC));

  assert.equal(returned, true);                     // async responder kept the channel open
  assert.equal(reply.ok, true);
  assert.equal(reply.result.status, "complete");
  // The bootstrap actually opened a job for THIS platform and hit the driver's fetch.
  const open = chromeApi.sent.find((m) => m.type === BULK.open);
  assert.equal(open.platform, "pinterest");
  assert.equal(fetchCalls.length, 1);               // one board-feed page fetched
});

test("registerBulkController: ignores a non-START message so other handlers run", async () => {
  const chromeApi = fakeChromeApi();
  const { win } = fakePinterestWin();
  registerBulkController(win, chromeApi);

  const { reply, returned } = await dispatch(chromeApi, { type: "some-other-message" });

  assert.equal(returned, false);                    // declined → chrome tries other listeners
  assert.equal(reply, undefined);                   // never replied
  assert.equal(chromeApi.sent.length, 0);           // no sweep started
});

test("registerBulkController: an unsupported platform is refused with a typed error (7A)", async () => {
  const chromeApi = fakeChromeApi();
  const { win } = fakePinterestWin();
  registerBulkController(win, chromeApi);

  const { reply } = await dispatch(chromeApi,
    buildStartMessage({ platform: "flickr", input: {}, scope: "x" }));

  assert.equal(reply.ok, false);
  assert.match(reply.error, /unsupported-platform: flickr/);
  assert.equal(chromeApi.sent.length, 0);              // never opened a job
  assert.equal(win.__atelierSweepInFlight, undefined); // guard never set → a good START still works
});

test("registerBulkController: re-registration is idempotent (one listener, one sweep per click)", () => {
  const chromeApi = fakeChromeApi();
  const { win } = fakePinterestWin();
  registerBulkController(win, chromeApi);
  registerBulkController(win, chromeApi);           // e.g. the cold-tab re-injection

  assert.equal(chromeApi.listeners.length, 1);      // NOT two → a click can't double-sweep
  assert.equal(win.__atelierBulkController, true);
});

test("registerBulkController: a transport error replies ok:false, not an unhandled rejection", async () => {
  const chromeApi = fakeChromeApi({ openReply: { __error: "open job failed (HTTP 500)" } });
  const { win } = fakePinterestWin();
  registerBulkController(win, chromeApi);

  const { reply } = await dispatch(chromeApi, buildStartMessage(PIN_SPEC));

  assert.equal(reply.ok, false);
  assert.match(reply.error, /open job failed/);
});

// MARK: - per-tab sweep guard + X listener teardown (1A)

test("registerBulkController: a second START while a sweep runs is refused (per-tab guard)", async () => {
  const chromeApi = fakeChromeApi();
  // A board-feed fetch that blocks until released, so the first sweep stays in flight.
  let releaseFetch;
  const gate = new Promise((r) => { releaseFetch = r; });
  const win = {
    location: { host: "www.pinterest.com", origin: "https://www.pinterest.com" },
    document: { documentElement: { innerHTML: "" }, cookie: "csrftoken=t" },
    fetch: async () => {
      await gate;
      return { ok: true, json: async () => ({
        resource_response: { status: "success", http_status: 200, data: [], bookmark: "-end-" } }) };
    },
    addEventListener() {}, postMessage() {},
  };
  registerBulkController(win, chromeApi);

  const first = dispatch(chromeApi, buildStartMessage(PIN_SPEC));       // in flight (blocked on fetch)
  const second = await dispatch(chromeApi, buildStartMessage(PIN_SPEC)); // refused synchronously

  assert.equal(second.reply.ok, false);
  assert.equal(second.reply.error, "sweep-already-running");           // NOT a concurrent sweep

  releaseFetch();
  const firstReply = await first;
  assert.equal(firstReply.reply.ok, true);                             // the first sweep still completes
  await new Promise((r) => setTimeout(r, 0));                          // let the .finally guard-release run
  assert.equal(win.__atelierSweepInFlight, false);                     // guard released after settle
});

test("registerBulkController: the X message listener is torn down when the sweep settles (1A)", async () => {
  const chromeApi = fakeChromeApi();
  const listeners = [];
  const win = {
    location: { host: "x.com", origin: "https://x.com" },
    document: { body: {} },
    scrollTo() {},
    addEventListener: (type, fn) => listeners.push({ type, fn }),
    removeEventListener: (type, fn) => {
      const i = listeners.findIndex((l) => l.type === type && l.fn === fn);
      if (i >= 0) listeners.splice(i, 1);
    },
    postMessage() {},
  };
  registerBulkController(win, chromeApi);

  const X_SPEC = { platform: "twitter", input: {}, scope: "bookmarks" };
  // An empty (0-tweet) terminator page: X's clean end-of-timeline, so the source
  // completes at once with no idle-scroll sleeps.
  const emptyPage = { data: { bookmark_timeline_v2: { timeline: { instructions: [
    { type: "TimelineAddEntries", entries: [
      { content: { entryType: "TimelineTimelineCursor", cursorType: "Bottom", value: "END" } },
    ] },
  ] } } } };
  const BOOKMARKS_URL = "https://x.com/i/api/graphql/q/Bookmarks?variables=%7B%7D";

  const started = dispatch(chromeApi, buildStartMessage(X_SPEC));
  // The driver registered its message listener synchronously during dispatch; feed it
  // the terminator page (the live hook would deliver this via postMessage).
  const entry = listeners.find((l) => l.type === "message");
  assert.ok(entry, "the X driver installs a message listener");
  entry.fn({ source: win, data: { source: MSG_SRC, json: emptyPage, url: BOOKMARKS_URL } });

  const { reply } = await started;
  await new Promise((r) => setTimeout(r, 0)); // let the .finally dispose() run

  assert.equal(reply.ok, true);
  assert.equal(reply.result.status, "complete");
  assert.equal(listeners.length, 0, "the message listener is removed on settle — no per-launch leak");
  assert.equal(win.__atelierSweepInFlight, false);
});

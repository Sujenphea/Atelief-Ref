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
  REDNOTE_FEED_MESSAGE_SOURCE as REDNOTE_FEED_SRC,
} from "../src/bulk-messages.js";

/** A fake `chromeApi`: records added listeners + sent messages, answers the bulk
 * protocol, and backs storage with a plain object. `openReply` overrides the open
 * answer so a test can inject a transport error (an `{ __error }` envelope). */
function fakeChromeApi({ openReply = { jobId: "JOB-1", caps: null }, boardFeed, known = [] } = {}) {
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
          case BULK.known: return known;
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
  // Deliver to EVERY message listener, the way the window does — the X driver installs
  // two (the timeline listener and the hook-proxy's reply listener) and which one is
  // registered first is not a contract.
  for (const listener of listeners.filter((l) => l.type === "message")) {
    listener.fn({ source: win, data: { source: MSG_SRC, json: emptyPage, url: BOOKMARKS_URL } });
  }

  const { reply } = await started;
  await new Promise((r) => setTimeout(r, 0)); // let the .finally dispose() run

  assert.equal(reply.ok, true);
  assert.equal(reply.result.status, "complete");
  assert.equal(listeners.length, 0, "the message listener is removed on settle — no per-launch leak");
  assert.equal(win.__atelierSweepInFlight, false);
});

// MARK: - the rednote driver's own wiring (098 2A, changelog 497)
//
// `buildRednoteDriver` is where expansion is actually plugged in, and since 2A what it
// plugs in changed shape: the source is handed the EXPANDER (it drives `attemptNote` /
// `retireNote` per note) and a STEP SCROLLER that walks the virtualised grid, instead of one
// page-at-a-time `expandItems`. Nothing else reaches that wiring — every other test of the
// expansion pass builds its own source — so a mis-wire here would be invisible until a live
// sweep, which is how this feature's defects have been found so far.

/**
 * A fake rednote board page. The board's own feed response is delivered through the MAIN-
 * world hook's message envelope, exactly as `rednote-hook.js` posts it. The document renders
 * the board's profile anchor but NO note card, which is the live grid's ordinary state for a
 * note that is not on screen — so the pass concedes the note rather than opening it, and the
 * test costs no paced note-open.
 */
function fakeRednoteWin({ noteId, boardId }) {
  const listeners = [];
  const state = { scrolled: [], listeners };
  const anchors = [`/user/profile/65d3e54f000000000503359d`];
  const feedPage = {
    code: 0,
    success: true,
    msg: "成功",
    data: {
      has_more: false,
      cursor: "",
      notes: [{
        note_id: noteId,
        type: "normal",
        display_title: "t",
        xsec_token: "AB40tok",
        user: { user_id: "u1", nickname: "n" },
        cover: {
          file_id: "fid",
          url: "",
          url_pre: "http://sns-webpic-qc.xhscdn.com/2026/fid!nc_n_webp_mw_1",
          url_default: "http://sns-webpic-qc.xhscdn.com/2026/fid!nc_n_webp_mw_1",
          info_list: [{ image_scene: "WB_DFT", url: "http://sns-webpic-qc.xhscdn.com/2026/fid!nc_n_webp_mw_1" }],
          width: 100,
          height: 100,
        },
      }],
    },
  };
  const feedUrl = `//webapi.rednote.com/api/sns/web/v1/board/note`
    + `?board_id=${boardId}&num=30&cursor=&image_formats=jpg,webp,avif`;
  const win = {
    location: { host: "www.rednote.com", origin: "https://www.rednote.com", pathname: `/board/${boardId}` },
    // Shorter than the viewport, so the walk is at the foot of the document on its first
    // look and the pass concedes in one round instead of waiting out its settle twelve times.
    innerHeight: 1000,
    scrollY: 0,
    document: {
      body: { scrollHeight: 800 },
      querySelectorAll: (selector) => {
        const needle = /a\[href\*="([^"]*)"\]/.exec(selector);
        return anchors
          .filter((href) => needle && needle[1] && href.includes(needle[1]))
          .map((href) => ({ getAttribute: () => href, click() {}, scrollIntoView() {} }));
      },
      dispatchEvent: () => true,
    },
    history: { back() {}, scrollRestoration: "auto" },
    KeyboardEvent: function KeyboardEvent() {},
    scrollTo: (x, y) => state.scrolled.push(y),
    addEventListener: (type, fn) => listeners.push({ type, fn }),
    removeEventListener: (type, fn) => {
      const index = listeners.findIndex((l) => l.type === type && l.fn === fn);
      if (index >= 0) listeners.splice(index, 1);
    },
    // The hook's replay: it re-posts what the board fetched before the sweep attached,
    // which for a board the user just opened is the opening slice.
    postMessage: () => {
      for (const listener of listeners.filter((l) => l.type === "message")) {
        listener.fn({ source: win, data: { source: REDNOTE_FEED_SRC, json: feedPage, url: feedUrl } });
      }
    },
  };
  return { win, state, noteId };
}

test("registerBulkController: an expansion sweep wires the EXPANDER and the walk, not a page hook", async () => {
  const boardId = "69322476000000001202811f";
  const noteId = "6a9f696e000000000d020daa";
  // The note is already in the library, so the engine SKIPS the relay (no pace, no relay):
  // this test is about the driver's wiring, and a real relay would cost the engine's full
  // pacing gap for nothing this test asks about.
  const chromeApi = fakeChromeApi({ known: [noteId] });
  const { win, state } = fakeRednoteWin({ noteId, boardId });
  registerBulkController(win, chromeApi);

  const { reply } = await dispatch(chromeApi, buildStartMessage({
    platform: "rednote", input: { boardId }, scope: `board:${boardId}`, expandNotes: true,
  }));

  await new Promise((resolve) => { setTimeout(resolve, 0); });   // let the .finally dispose() run

  assert.equal(reply.ok, true, `the sweep failed: ${reply.error}`);
  assert.equal(reply.result.status, "complete", `the sweep halted: ${reply.result.error}`);
  // The expander is wired: a cover-only sweep reports `expansion: null`, and one wired to
  // the old page-at-a-time hook would never have driven `attemptNote` at all.
  const expansion = reply.result.expansion;
  assert.ok(expansion, "an expansion sweep reported no expansion stats — the expander is not wired");
  assert.equal(expansion.mode, "expansion");
  assert.equal(expansion.attempted, 1, "the board's one note was never put to the expander");
  assert.equal(expansion.unreachable, 1, "a note with no card on the page was not conceded");
  assert.equal(expansion.opened, 0, "a note with no card was clicked anyway");
  // …and the walk is wired: the pass asked the page to step, found itself already at the
  // foot of a document shorter than the viewport, and nudged the paging scroll.
  assert.ok(state.scrolled.length > 0, "the board was never scrolled at all");
  assert.equal(state.listeners.length, 0, "the message listener leaked past the sweep");
});

test("registerBulkController: a COVER sweep of the same board opens nothing and reports no expansion", async () => {
  // The other half of the toggle, through the same wiring: with `expandNotes` off the
  // driver builds no expander, no note driver and no walk — the pass verified live against
  // a real 116-note board, untouched by any of 2A.
  const boardId = "69322476000000001202811f";
  const noteId = "6a9f696e000000000d020daa";
  const chromeApi = fakeChromeApi({ known: [noteId] });
  const { win } = fakeRednoteWin({ noteId, boardId });
  registerBulkController(win, chromeApi);

  const { reply } = await dispatch(chromeApi, buildStartMessage({
    platform: "rednote", input: { boardId }, scope: `board:${boardId}`,
  }));

  assert.equal(reply.ok, true);
  assert.equal(reply.result.status, "complete");
  assert.equal(reply.result.expansion, null, "a cover sweep reported expansion stats");
});

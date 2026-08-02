// Atelier Capture — the browser-API shim contract (013 · A, narrowed).
//
// `src/browser.js` is the one door the glue goes through so a Safari Web Extension can
// wrap this same JS. These tests pin the three worlds it has to work in, because none
// of them can be reached from the other two by inspection:
//
//   1. a `chrome`-only global (today's Chrome MV3 build),
//   2. a `browser`-only global (Safari / Firefox — promise-shaped),
//   3. NEITHER, which is `node --test` itself — importing must not throw, because
//      sw.js and base-url.js are imported here for their pure cores.
//
// The property under test is that (1) and (2) reach the SAME underlying methods with
// the SAME arguments. The one place they legitimately diverge is
// `contextMenus.removeAll`: Chrome is driven by callback, Safari by promise, and both
// must present as a promise to the caller — a `.then(create)` in sw.js that silently
// never fired would leave the extension with no context menu and no error.

import { test } from "node:test";
import assert from "node:assert/strict";

import { createBrowserApi, browser } from "../src/browser.js";

/**
 * A recording fake of the native surface. `style: "promise"` mimics Safari/Firefox —
 * `contextMenus.removeAll` returns a promise and THROWS if handed a callback, which is
 * the actual failure mode the shim exists to prevent.
 */
function fakeNative(style) {
  const calls = [];
  const record = (name) => (...args) => { calls.push([name, ...args]); return `${name}-result`; };
  const event = (name) => ({ addListener: (fn) => calls.push([name, fn]) });
  return {
    calls,
    api: {
      runtime: {
        getURL: record("runtime.getURL"),
        sendMessage: record("runtime.sendMessage"),
        onMessage: event("runtime.onMessage.addListener"),
        onInstalled: event("runtime.onInstalled.addListener"),
      },
      storage: {
        local: {
          get: record("storage.local.get"),
          set: record("storage.local.set"),
          remove: record("storage.local.remove"),
        },
      },
      tabs: { query: record("tabs.query"), sendMessage: record("tabs.sendMessage") },
      scripting: { executeScript: record("scripting.executeScript") },
      action: {
        setBadgeText: record("action.setBadgeText"),
        setBadgeBackgroundColor: record("action.setBadgeBackgroundColor"),
        setTitle: record("action.setTitle"),
      },
      contextMenus: {
        create: record("contextMenus.create"),
        onClicked: event("contextMenus.onClicked.addListener"),
        removeAll: (callback) => {
          calls.push(["contextMenus.removeAll", callback]);
          if (style === "promise") {
            if (callback) throw new TypeError("removeAll takes no callback under `browser`");
            return Promise.resolve();
          }
          callback();          // Chrome's callback form
          return undefined;
        },
      },
    },
  };
}

const chromeScope = () => { const f = fakeNative("callback"); return { scope: { chrome: f.api }, calls: f.calls }; };
const browserScope = () => { const f = fakeNative("promise"); return { scope: { browser: f.api }, calls: f.calls }; };

/** Everything the extension's glue actually calls, in one pass, so the two engines can
 * be compared call-for-call. Mirrors the real call sites in sw.js / popup.js /
 * options.js / base-url.js / bulk-controller.js. */
async function exerciseEverySurface(api, listener) {
  api.runtime.getURL("src/bulk-controller.js");
  await api.runtime.sendMessage({ type: "atelier-bulk-open" });
  api.runtime.onMessage.addListener(listener);
  api.runtime.onInstalled.addListener(listener);
  await api.storage.local.get("atelierToken");
  await api.storage.local.set({ atelierToken: "t" });
  await api.storage.local.remove("atelierBaseCache");
  await api.tabs.query({ active: true, currentWindow: true });
  await api.tabs.sendMessage(7, { type: "start" });
  await api.scripting.executeScript({ target: { tabId: 7 } });
  api.action.setBadgeText({ text: "✓" });
  api.action.setBadgeBackgroundColor({ color: "#2e8b57" });
  api.action.setTitle({ title: "Atelier — Saved." });
  await api.contextMenus.removeAll();
  api.contextMenus.create({ id: "atelier-save" });
  api.contextMenus.onClicked.addListener(listener);
}

// --- The three worlds ------------------------------------------------------

test("createBrowserApi: with neither global, it resolves to an inert shim (never throws)", () => {
  const api = createBrowserApi({});

  assert.equal(api.available, false);
  // Namespaces are null, NOT missing — the call sites guard on them exactly the way
  // they used to guard on `typeof chrome !== "undefined"`.
  for (const ns of ["runtime", "storage", "tabs", "scripting", "action", "contextMenus"]) {
    assert.equal(api[ns], null, `${ns} is null with no global`);
  }
});

test("browser.js imports cleanly under node --test — no chrome, no browser", () => {
  // The module-level `createBrowserApi()` already ran at import; reaching here at all
  // is the assertion. This is what lets sw.js/base-url.js be imported for their cores.
  assert.equal(typeof globalThis.chrome, "undefined");
  assert.equal(typeof globalThis.browser, "undefined");
  assert.equal(browser.available, false);
  assert.equal(browser.storage, null);
});

test("createBrowserApi: a chrome-only global is available and callback-styled", () => {
  const api = createBrowserApi(chromeScope().scope);
  assert.equal(api.available, true);
  assert.equal(api.promiseStyle, false);
});

test("createBrowserApi: a browser-only global is available and promise-styled", () => {
  const api = createBrowserApi(browserScope().scope);
  assert.equal(api.available, true);
  assert.equal(api.promiseStyle, true);
});

test("createBrowserApi: `browser` wins when both globals exist (Safari publishes both)", () => {
  const chromeSide = fakeNative("callback");
  const browserSide = fakeNative("promise");
  const api = createBrowserApi({ chrome: chromeSide.api, browser: browserSide.api });

  api.runtime.getURL("x");

  assert.equal(api.promiseStyle, true);
  assert.equal(browserSide.calls.length, 1);   // the promise-shaped global was used
  assert.equal(chromeSide.calls.length, 0);    // ...and the callback one ignored
});

// --- Same calls under both engines ----------------------------------------

test("the same glue produces the same underlying calls under chrome and under browser", async () => {
  const listener = () => true;
  const underChrome = chromeScope();
  const underBrowser = browserScope();

  await exerciseEverySurface(createBrowserApi(underChrome.scope), listener);
  await exerciseEverySurface(createBrowserApi(underBrowser.scope), listener);

  // `removeAll`'s trailing argument is the one deliberate difference (a callback under
  // chrome, nothing under browser) — compare it separately, everything else verbatim.
  const strip = (calls) => calls.map((c) => (c[0] === "contextMenus.removeAll" ? [c[0]] : c));
  assert.deepEqual(strip(underChrome.calls), strip(underBrowser.calls));

  // And the whole inventory really was exercised, in order.
  assert.deepEqual(strip(underChrome.calls).map((c) => c[0]), [
    "runtime.getURL", "runtime.sendMessage",
    "runtime.onMessage.addListener", "runtime.onInstalled.addListener",
    "storage.local.get", "storage.local.set", "storage.local.remove",
    "tabs.query", "tabs.sendMessage",
    "scripting.executeScript",
    "action.setBadgeText", "action.setBadgeBackgroundColor", "action.setTitle",
    "contextMenus.removeAll", "contextMenus.create",
    "contextMenus.onClicked.addListener",
  ]);
});

test("arguments pass through untouched (a wrapper must not reshape a details object)", async () => {
  const underChrome = chromeScope();
  const api = createBrowserApi(underChrome.scope);
  const injection = { target: { tabId: 7 }, func: () => {} };

  await api.scripting.executeScript(injection);
  await api.storage.local.get(["atelierToken", "atelierBaseOverride"]);
  await api.tabs.sendMessage(7, { type: "atelier-bulk-start" });

  assert.deepEqual(underChrome.calls[0], ["scripting.executeScript", injection]);
  assert.deepEqual(underChrome.calls[1],
    ["storage.local.get", ["atelierToken", "atelierBaseOverride"]]);
  assert.deepEqual(underChrome.calls[2], ["tabs.sendMessage", 7, { type: "atelier-bulk-start" }]);
});

test("return values pass through — executeScript's array reaches the caller", async () => {
  const scope = { chrome: { scripting: { executeScript: async () => [{ result: { url: "u" } }] } } };
  const [injected] = await createBrowserApi(scope).scripting.executeScript({});
  assert.deepEqual(injected.result, { url: "u" });
});

// --- contextMenus.removeAll: the one real divergence -----------------------

test("contextMenus.removeAll is a promise under chrome (callback form, wrapped)", async () => {
  const underChrome = chromeScope();
  const api = createBrowserApi(underChrome.scope);

  const result = api.contextMenus.removeAll();
  assert.equal(typeof result.then, "function");   // a promise, not the raw undefined
  await result;

  // Chrome IS given a callback — that's what settles the promise.
  assert.equal(typeof underChrome.calls[0][1], "function");
});

test("contextMenus.removeAll is a promise under browser, and is given NO callback", async () => {
  const underBrowser = browserScope();
  const api = createBrowserApi(underBrowser.scope);

  // The fake throws on a callback, mirroring the real `browser.*` contract — so this
  // resolving at all is the proof the shim didn't hand one over.
  await api.contextMenus.removeAll();

  assert.equal(underBrowser.calls[0][1], undefined);
});

test("removeAll().then(create) — sw.js's install sequence — ordered on both engines", async () => {
  for (const make of [chromeScope, browserScope]) {
    const world = make();
    const api = createBrowserApi(world.scope);

    await api.contextMenus.removeAll().then(() => api.contextMenus.create({ id: "atelier-save" }));

    // create runs AFTER removeAll, never before: reversed, the menu would be wiped.
    assert.deepEqual(world.calls.map((c) => c[0]),
      ["contextMenus.removeAll", "contextMenus.create"]);
  }
});

// --- Listener passthrough --------------------------------------------------

test("onMessage hands the listener through unwrapped so `return true` still works", () => {
  const underChrome = chromeScope();
  const api = createBrowserApi(underChrome.scope);
  // sw.js returns true to keep the channel open for an async sendResponse; a wrapper
  // that returned its own value would silently break every bulk reply.
  const listener = () => true;

  api.runtime.onMessage.addListener(listener);

  assert.equal(underChrome.calls[0][1], listener);   // the SAME function object
});

// --- Partial surfaces ------------------------------------------------------

test("a global missing a namespace yields null there, not a throw on import", () => {
  // A content script's `chrome` has runtime + storage but no tabs/scripting/action.
  const api = createBrowserApi({ chrome: { runtime: {}, storage: { local: {} } } });

  assert.equal(api.available, true);
  assert.ok(api.runtime);
  assert.ok(api.storage);
  assert.equal(api.tabs, null);
  assert.equal(api.scripting, null);
  assert.equal(api.action, null);
  assert.equal(api.contextMenus, null);
  // A namespace present but without the event still yields a null event, not a crash —
  // this is the shape sw.js's `browser.runtime && browser.runtime.onMessage` guard reads.
  assert.equal(api.runtime.onMessage, null);
});

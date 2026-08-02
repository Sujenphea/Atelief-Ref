// Atelier Capture — the ONE door to the extension API (013 · A, narrowed).
//
// Everything in `src/` that isn't glue is already pure: the extractors, the bulk
// engine, harvest, net, drift — none of them name `chrome`. Only a handful of files
// touch the browser at all. This module is the seam those files go through, so a
// future Safari Web Extension target (013 · A) is packaging + a manifest, not a
// rewrite of the tree. No `webextension-polyfill`: this repo vendors nothing, and the
// surface below is *only* what the inventory found — six namespaces, sixteen methods.
//
// THE TRAP, and the whole reason this file exists: Chrome exposes `chrome` and Safari
// (like Firefox) exposes `browser`, and the two disagree about callbacks. Under MV3
// most of Chrome's surface returns a promise when you omit the callback, so it already
// matches `browser` — but `contextMenus.removeAll` is written callback-first in the
// wild, and passing a callback to a `browser.*` method is a TypeError there rather
// than a promise. So the style is decided ONCE, from which global we resolved, and
// only `removeAll` is actually promisified. Guessing per call would be worse than the
// bug it's avoiding.
//
// IMPORT-SAFE WITH NEITHER GLOBAL: `node --test` has no `chrome` and no `browser`, and
// files like sw.js are imported there for their pure core. So this module resolves to
// a shim whose namespaces are `null` — never a throw at import time — and the call
// sites keep the same shape of guard they had against `typeof chrome !== "undefined"`
// (see the `typeof window` guard at the foot of twitter-hook.js for the house style).
//
// NOT COVERED, deliberately: the MAIN-world classic scripts (`hook-core.js`,
// `twitter-hook.js`) and the classic module loader (`bulk-loader.js`). A content script
// injected as a classic script cannot `import`, so an import here would break injection
// outright; bulk-loader.js repeats the two-token global resolution inline instead.

/**
 * Build the shim from a global scope. Exported for the contract tests, which drive it
 * with a fake `chrome`-only scope, a fake `browser`-only scope, and an empty one — the
 * three worlds the extension has to load in.
 *
 * `browser` wins over `chrome` when both exist: Safari publishes both names, and only
 * the `browser` one is promise-shaped all the way down.
 */
export function createBrowserApi(scope = globalThis) {
  const host = scope.browser ?? scope.chrome ?? null;
  // Promise style is a property of WHICH global answered, not of the method.
  const promiseStyle = !!scope.browser;
  if (!host) {
    return {
      available: false, promiseStyle: false,
      runtime: null, storage: null, tabs: null, scripting: null,
      action: null, contextMenus: null,
    };
  }

  const { runtime, storage, tabs, scripting, action, contextMenus } = host;
  const local = storage ? storage.local : null;
  // Listeners are handed through UNWRAPPED: `runtime.onMessage` reads the listener's
  // return value (`true` keeps the channel open for an async `sendResponse`), so a
  // wrapper that returned anything of its own would break the async reply.
  const on = (event) => (event ? { addListener: (fn) => event.addListener(fn) } : null);

  return {
    available: true,
    promiseStyle,

    runtime: runtime ? {
      /** Extension-relative URL → absolute. Synchronous in both engines. */
      getURL: (path) => runtime.getURL(path),
      /** Content script → SW. Promise in MV3 Chrome and in Safari alike. */
      sendMessage: (message) => runtime.sendMessage(message),
      onMessage: on(runtime.onMessage),
      onInstalled: on(runtime.onInstalled),
    } : null,

    // `{ load, save, remove }` is deliberately NOT the shape here: callers
    // (base-url.js, bulk-controller.js) wrap this into that shape themselves, and
    // keeping the raw `get/set/remove` means those wrappers didn't have to change.
    storage: local ? {
      local: {
        get: (keys) => local.get(keys),
        set: (items) => local.set(items),
        remove: (keys) => local.remove(keys),
      },
    } : null,

    tabs: tabs ? {
      query: (info) => tabs.query(info),
      sendMessage: (tabId, message) => tabs.sendMessage(tabId, message),
    } : null,

    scripting: scripting ? {
      executeScript: (injection) => scripting.executeScript(injection),
    } : null,

    action: action ? {
      setBadgeText: (details) => action.setBadgeText(details),
      setBadgeBackgroundColor: (details) => action.setBadgeBackgroundColor(details),
      setTitle: (details) => action.setTitle(details),
    } : null,

    contextMenus: contextMenus ? {
      /** Synchronous, returns the id, in both engines. */
      create: (properties) => contextMenus.create(properties),
      /**
       * The one genuine divergence (see the header). Always a promise here, so the
       * caller can `.then(create)` without knowing which engine it's on. Under
       * `chrome` we pass the callback — under `browser` passing one would throw.
       */
      removeAll: promiseStyle
        ? () => contextMenus.removeAll()
        : () => new Promise((resolve) => contextMenus.removeAll(() => resolve())),
      onClicked: on(contextMenus.onClicked),
    } : null,
  };
}

/** The live shim, resolved once at import. `available` is false under `node --test`. */
export const browser = createBrowserApi();

export default browser;

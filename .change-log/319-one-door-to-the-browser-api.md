# 319 — One Door to the Browser API (013 · A · K1, narrowed)

The extension now reaches the browser through exactly one module. Nothing moved,
nothing was renamed, no test was edited — the point is that a Safari Web
Extension target ([013](../.docs/feature-todo/013-capture-breadth.md) · A) can
wrap this same JS as packaging and glue rather than as a rewrite.

## Summary

- **`extension/src/browser.js`** (new) — resolves `globalThis.browser ??
  globalThis.chrome` once and exports the six namespaces the extension actually
  uses. Hand-written; no `webextension-polyfill`, because this repo vendors
  nothing and the full polyfill is a large surface for a small need.
- **The glue routes through it**: `sw.js`, `popup.js`, `options.js`,
  `base-url.js`, `bulk-controller.js`. Their behaviour is unchanged — the diff is
  a token swap plus two guards that got narrower rather than wider.
- **`test/browser.test.js`** (new, 13) — the shim's contract under a `chrome`-only
  global, under a `browser`-only global, and under neither.

## The scope line, and why it isn't 013's

013 · A proposes a `shared/` + `chrome/` + `safari/` relocation. That was not
built. The pure modules — the extractors, the bulk engine, `harvest`, `net`,
`media-hosts`, `drift` — already contain no `chrome.*` at all; they are *already*
`shared/` in everything but their path. Moving them would have rewritten every
import in the tree and put ~400 green tests through a churn that buys, at the
end, the same property this change buys without it: the browser API has one
owner. The relocation stays available later, cheaper, once the Safari target
exists and can say what it actually needs.

## The inventory, not a guess

The shim exports what a `grep` for `chrome.` under `src/` found and nothing else
— six namespaces, sixteen methods: `runtime` (`getURL`, `sendMessage`,
`onMessage`, `onInstalled`), `storage.local` (`get`, `set`, `remove`), `tabs`
(`query`, `sendMessage`), `scripting` (`executeScript`), `action`
(`setBadgeText`, `setBadgeBackgroundColor`, `setTitle`), and `contextMenus`
(`create`, `removeAll`, `onClicked`). Speculative surface is how a shim becomes a
second API to maintain.

## Promise style is decided once, not per call

Chrome exposes `chrome`, Safari and Firefox expose `browser`, and the two
disagree about callbacks. Under MV3 most of Chrome's surface already returns a
promise when you omit the callback, so the honest promisification list is one
entry long: `contextMenus.removeAll`, whose callback form is what `sw.js` was
written against and whose callback form is a `TypeError` under `browser`.

So the style is read from *which global answered* — `browser` wins when both are
present, because Safari publishes both names and only that one is promise-shaped
all the way down — and `removeAll` presents as a promise either way. Sniffing per
call would mean handing a callback to a promise-only method to find out, which is
the bug it was supposed to prevent.

`removeAll().then(create)` is the sequence that matters: reversed or dropped, the
install leaves the extension with no context menu and no error to explain it.
Both engines are pinned to that order.

## Importing with no browser at all

`node --test` has neither global, and `sw.js` and `base-url.js` are imported
there for their pure cores. So the shim resolves to an inert object whose
namespaces are `null` — never a throw at import — and the call sites guard on
`browser.storage` / `browser.runtime.onMessage` exactly where they used to guard
on `typeof chrome !== "undefined"`. Same shape of guard, same house style as the
`typeof window` guard at the foot of `twitter-hook.js`.

`sw.js`'s context-menu guard was `chrome.action` while the block also reaches for
`contextMenus`; it now checks both. Under Chrome the two are always present
together, so this is a stricter guard rather than a behaviour change.

## The three files the shim deliberately does not cover

`hook-core.js` and `twitter-hook.js` are MAIN-world **classic** scripts injected
at `document_start` — they cannot `import`, and neither names the browser API
anyway. `bulk-loader.js` is the classic ISOLATED-world module loader; a static
import there would turn it into a module and break its injection outright, so it
repeats `globalThis.browser ?? globalThis.chrome` inline for its single
`runtime.getURL` call. Two duplicated tokens are cheaper than the alternative,
and its header now says so.

## Files changed

- `extension/src/browser.js` — new. `createBrowserApi(scope)` (exported for the
  tests) plus the live `browser` resolved at import.
- `extension/src/sw.js` — token/storage/scripting/action/contextMenus glue and
  both registration guards.
- `extension/src/popup.js` — `tabs.query`, `tabs.sendMessage`,
  `scripting.executeScript`.
- `extension/src/options.js` — `storage.local` get/set/remove.
- `extension/src/base-url.js` — `defaultStorage()` reads the shim; the in-memory
  fallback is untouched, so the port-resolution tests never see a browser.
- `extension/src/bulk-controller.js` — the bootstrap hands `registerBulkController`
  the shim. The function already took the API as an argument (which is why the
  bootstrap tests drive it with a fake), so only the parameter *name* changed,
  `chromeApi` → `browserApi`.
- `extension/src/bulk-loader.js` — inline two-token resolution + the note on why.
- `extension/test/browser.test.js` — new, 13 tests.

`bulk-sw.js` turned out to need no change: it named `chrome` only in prose.

## Test results

`extension/` — `npm test` (`node --test`, Node v22.17.1): **410 pass, 0 fail**.
That is the pre-existing **397** unchanged — not one test file was edited — plus
the 13 new shim-contract tests.

`npm run drift-check`: **no drift**, every check satisfied its invariants. It
exits 1 on the pre-existing Instagram fixture staleness (captured 2026-07-15, 18d
against a 14d window), which this change does not touch.

## Migration notes

**None.** No schema, no stored key, no message type, no manifest change. Every
call reaches the same underlying method with the same arguments it did before;
the only new file paths are `src/browser.js` and `test/browser.test.js`.

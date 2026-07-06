# 071 — X timeline hook is injectable again (classic script, no `export`)

Phase 9 T9 (X bookmarks) came back **all zeros** — the sweep enumerated nothing and
completed. Root cause: the entire X interception path was silently broken.

## Root cause

`manifest.json` injects `src/twitter-hook.js` **raw** as a classic MAIN-world content
script (this extension has no bundler). But the file declared its functions with
top-level **`export`** (`export const` / `export function`). **`export` is a
SyntaxError in a classic script**, so Chrome failed to parse the whole file → the
auto-install tail never ran → `window.fetch` was never wrapped → no `Bookmarks`
response was ever captured → the push→pull source scrolled `maxIdleRounds` times, saw
nothing, and ended `complete` with zero counts.

It stayed hidden because the **unit test imported the file as an ES module** (node
`type: module`), where `export` is valid — and the X path had never been run live until
T9. The tests were green against a shape that could never load in the browser.

## Fix (option A — one file, no duplication)

- **`twitter-hook.js`** — drop the `export` keywords; the functions are now plain
  top-level declarations, making the file a valid classic script. The auto-install tail
  already used only globals, so it's unchanged. (`TIMELINE_MESSAGE_SOURCE` is consumed
  from `bulk-messages.js` everywhere else, so nothing imported these symbols from here
  except the test.)
- **`test/bulk-twitter.test.js`** — instead of ESM-importing the hook, load the real
  file with `readFileSync` + `new Function("window", src)` and lift out its functions.
  The test now verifies the **exact injected artifact** as the classic script it ships
  as. Added a guard test — `new Function(src)` must not throw — that fails loudly at the
  true failure point if a static `export`/`import` is ever reintroduced.

## Verified

`node --test` **180 pass** (+1 guard). Live re-probe: `window.__atelierTimelineHookInstalled`
should now read `true` on x.com after an extension + tab reload. Requires an **extension
reload**. T9 live re-run pending.

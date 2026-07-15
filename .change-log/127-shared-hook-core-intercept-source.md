# 127 — Shared hook-core + generic intercept source (002 · B1)

## Summary

Refactored the X interception stack so the Instagram driver (B3) forks nothing —
settled decisions 5A (shared hook core) and 2A (generalized source). Behaviour-preserving
for X: the whole extension suite is green and the X regression-gate suites are unchanged.

Two pieces of machinery, previously X-specific, are now platform-agnostic:

1. **`hook-core.js`** (new, classic MAIN-world script) — `installResponseHook({ target,
   post, isMatch, replaySource, bufferLimit })` carries ALL the interception machinery:
   `fetch` + `XMLHttpRequest` wrapping, the bounded replay buffer + replay listener, the
   never-break-the-page guards, and the install-once idempotency flag. Forwarding is
   deliberately **status-blind** so a 4xx challenge body (IG `checkpoint_required`, a feed
   429) reaches the driver — the 3A signal. Published on `window.__atelierInstallResponseHook`
   for the per-site hook loaded after it.
2. **`intercept-source.js`** (new) — `createInterceptSource({ parsePage, matchesScope,
   scroll, sleep, host, settleMs, maxIdleRounds, scope, StallError })`: the push→pull
   queue / auto-scroll / stall-detection loop, parameterized by an injected page parser
   and scope matcher. A page may carry a fatal `error` (an IG challenge) which arrives on
   the push channel and is re-raised from `enumerate` so the engine halts resumable (3A).
   `SourceStallError` is the generic stall type.

`twitter-hook.js` and `twitter-source.js` shrink to **thin configs**: the X URL matcher +
message tags, and the X page parser (`parseTimelinePage` → `{ items, endOfFeed }`, end =
0-tweet page) + scope matcher. `TimelineStallError` is kept as a named subclass so X
callers/tests are unchanged.

## Manifest

The X MAIN-world content script is now an **ordered pair**:
`"js": ["src/hook-core.js", "src/twitter-hook.js"]` — core must load first so it can
publish the installer. `web_accessible_resources` already covers `src/*.js`.

## Files changed

- `extension/src/hook-core.js` — new (shared classic machinery).
- `extension/src/intercept-source.js` — new (generic push→pull source).
- `extension/src/twitter-hook.js` — slimmed to matcher + tags + load-order-guarded install.
- `extension/src/twitter-source.js` — slimmed to a `createInterceptSource` adapter.
- `extension/manifest.json` — ordered `[hook-core, twitter-hook]` pair.
- `extension/test/hook-core.test.js` — new: the machinery matrix (10A) — fetch/XHR
  forwarding, idempotency, buffer/replay bound, **4xx-body forwarding**, non-match
  silence, and the load-order pair tests (core-first installs; site-without-core fails
  loudly via console.error but never throws; inert on a non-matching host).
- `extension/test/bulk-twitter.test.js` — the hook-machinery tests moved to
  hook-core.test.js; kept the X parser/scope/graphqlOp tests, the classic-script syntax
  guard, and the wire-constant sync check.

## Test results

`node --test`: **314 pass / 0 fail** (was 308; net +6 from relocating 8 machinery tests
into 14 hook-core tests). X regression-gate suites (twitter-source, bulk-twitter,
bulk-twitter-integration, drift, bulk-controller) unchanged and green.

## Migration notes

No app-side or schema change. Any future MAIN-world hook should be a config over
`installResponseHook` + `createInterceptSource`, not a fork. The manifest ordering
(`hook-core` before the site hook) is load-bearing and pinned by a test.

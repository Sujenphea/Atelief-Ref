# 061 — Bulk import: content-script controller + SW relay (Phase 6)

Phase 6 of bulk import ([.docs/018](../.docs/018-bulk-import-plan.md)): the wiring
that turns the pure engine + two drivers into a running feature — the durable
content-script loop, the thin SW relay, checkpointing, and the manifest. Decision 1A.

## Architecture decision (the design doc was ambiguous)

The Phase-6 verify criterion — **"kill the SW mid-sweep → the loop continues"** —
settles where the engine runs: in the **content script** (durable while the tab is
open), NOT the SW (torn down at ~30s idle). The SW is a **thin relay**: only it can
reach the loopback app (`127.0.0.1`) without CORS, so every localhost op — open a
job, load the known set, relay an item, close the job — is proxied to the SW over
`chrome.runtime` messaging. Each message resets the SW idle timer, which is what
keeps it alive across a long sweep.

## Summary (all cores pure/injectable + unit-tested)

- **`bulk-endpoint.js`** — the SW-side `/jobs` wrappers (`openJob` /
  `fetchKnownSources` / `completeJob`), speaking Swift's `JobResponse` DTO. `endpoint.js`
  now exports a single `DEFAULT_BASE` both the ingest and jobs routes derive from.
- **`bulk-messages.js`** — the content↔SW protocol (`BULK.{open,known,relay,complete}`)
  + `isBulkMessage`, so the two sides can't drift on a string literal.
- **`bulk-sw.js`** — `handleBulkMessage(message, deps)`: the SW dispatcher. `relay`
  runs the SAME `ingestOne` tail single-item capture uses (C5), so a swept item and a
  manual save ingest identically.
- **`twitter-source.js`** — `createTwitterSource`: adapts the PUSH stream of
  intercepted X responses into the engine's PULL iterator, auto-scrolling to page and
  ending on a 0-tweet page or after N idle scrolls (a bottom / DOM wall).
- **`bulk-controller.js`** — `runBulkSweep(spec, deps)`: the orchestration core (open
  → load known-set → drive the engine, relaying each item to the SW and classifying
  the result → close with the right ledger status). Halt → the job closes `halted`
  (resumable); clean finish → `complete`.
- **`bulk-pinterest.js`** — added the pure session-bootstrap helpers
  `scrapePinterestAppVersion` (the REQUIRED runtime app-version, Phase-0) + `readCookie`
  (the non-HttpOnly `csrftoken`, no `cookies` permission).

## MV3 module-loading (a real constraint, handled)

A manifest content script (`js`) is a CLASSIC script — it can't `import`. So:
- **`twitter-hook.js`** is now **self-contained** (no imports), injected as a MAIN-world
  classic script at `document_start` (before X's fetches). Its `TIMELINE_MESSAGE_SOURCE`
  + `isTimelineRequest` are duplicated from `bulk-messages.js` as literals with
  KEEP-IN-SYNC comments — unavoidable across the MAIN-world boundary, and small.
- **`bulk-loader.js`** — a tiny classic ISOLATED content script that dynamic-`import()`s
  the controller module graph (allowed when the modules are `web_accessible_resources`).
- **`manifest.json`** — persistent `host_permissions` for x/twitter/pinterest(.co.uk);
  the two content scripts (MAIN hook + ISOLATED loader); `web_accessible_resources`
  for `src/*.js` so the dynamic imports resolve.

## Files changed

- New: `bulk-endpoint.js`, `bulk-messages.js`, `bulk-sw.js`, `twitter-source.js`,
  `bulk-controller.js`, `bulk-loader.js`.
- `twitter-hook.js` (self-contained; owns `isTimelineRequest`), `bulk-twitter.js`
  (drops the moved predicate), `bulk-pinterest.js` (+ bootstrap helpers),
  `endpoint.js` (`DEFAULT_BASE`), `sw.js` (thin bulk `onMessage` glue), `manifest.json`.
- Tests: `bulk-endpoint`, `bulk-sw`, `bulk-controller`, `twitter-source` (new);
  `bulk-pinterest` (+ bootstrap), `bulk-twitter` (predicate import moved).

## Not unit-tested (irreducible browser glue — Phase-9 E2E)

The `chrome.*`/`window` bootstrap: the MAIN-world injection actually capturing X's
fetches, the cross-world `postMessage`, the SW staying alive under item traffic, the
dynamic-import loader, and `chrome.storage` persistence. These are thin, guarded (a
`node --test` import is inert), and verified manually in Phase 9. Every decision-making
core beneath them IS tested.

## Verification

`npm test` green — 152 tests (132 pre-existing unchanged + 20 new): the /jobs
wrappers (request shape + error mapping), the SW dispatcher matrix, a full controller
sweep (open → known-skip → relay → complete, + halt→halted, + opt-in video), the X
push→pull source (paging, idle-termination, garbage-tolerance), and the Pinterest
bootstrap helpers. `manifest.json` validates; the `sw.js` and `bulk-controller.js`
module graphs load clean.

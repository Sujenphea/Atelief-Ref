# 078 — Bulk import: review hardening pass (13 fixes + test backfill)

A structured code review of the extension bulk-import system (architecture / code quality
/ tests / performance) surfaced 16 issues; 13 were fixed (3 deferred as premature). The
work landed **tests-first** — the untested controller-bootstrap + popup surface was pinned
BEFORE the behaviour changes that reshape it, so a regression there fails a unit test
rather than only a manual E2E.

Test count: **219 → 270 green** (`node --test`). Drift canary still clean.

## Behaviour fixes

- **1A — per-tab sweep guard + X listener teardown.** A second `START` on a page (double
  click / cold-tab re-injection racing the popup) is refused with `sweep-already-running`
  instead of running a second concurrent sweep. `buildTwitterDriver` now returns a
  `dispose` that REMOVES its `message` listener when the sweep settles — previously every
  launch leaked another live listener feeding a dead source.
- **2A — X idle exhaustion is a resumable STALL, not a false complete.** When scrolling
  stops yielding pages before a 0-tweet end page, the source throws `TimelineStallError`;
  the engine halts RESUMABLE (job closes `paused`, checkpoint kept). The old silent
  `return` read as "complete" and DELETED the checkpoint, stranding a half-swept timeline.
  Bumped defaults `settleMs 1500→2000`, `maxIdleRounds 3→4` (more patient before pausing).
- **3A/3B — SSRF guard + missing-content-type reject.** New pure `isAllowedMediaHost`
  (`media-hosts.js`) pins each platform's media bytes to its CDNs (twimg / pinimg);
  the bulk relay refuses any off-allowlist URL (→ permanentFailed) BEFORE the SW fetches
  it in the authenticated session. `fetchImage` now also refuses a MISSING content-type,
  not just a non-image one (an HTML/login page often omits it).
- **5A — auth wall halts resumable.** `ingestOne`/`fetchImage` thread the HTTP status
  through; the classifier turns a 401/403 (media-CDN cookie expired / bad app token) into
  a resumable halt instead of burning the rest of the board as `permanentFailed`.
- **7A — reject unknown platform + popup re-enable.** The controller rejects platforms
  outside `{pinterest, twitter}` with a typed `unsupported-platform` error (was: silent
  fall-through to the Pinterest driver). The popup re-enables Start on ANY terminal
  failure — a resolved `{ok:false}` too, not only a thrown rejection (it used to leave
  Start dead).
- **8A — checkpoint save is non-fatal.** `runSweep`'s checkpoint wraps `storage.save` in
  try/catch: a write failure logs and the sweep continues (a resume just re-skips via
  dedup) instead of aborting the whole sweep.
- **12A — close-tail cleanup is non-fatal.** `runBulkSweep` wraps the checkpoint
  `storage.remove`: a local cleanup failure logs rather than masking an
  otherwise-successful sweep. (A failed server `/complete` still propagates — the ledger
  close is load-bearing.)
- **13A — apply the server's byte caps.** The job-open `caps` (fetched but unused) now
  thread through the relay to `ingestOne`; `fetchImage` gains a Content-Length pre-check
  (mirroring the video path) and `downloadAndIngestVideo`'s cap is overridable by the
  server's authoritative value. Single-item capture passes no caps (server backstops).
- **14A — cheaper app_version scrape.** `scrapePinterestAppVersionFromDoc` scans inline
  `<script>` bodies first (small), falling back to the full-page `innerHTML` only if none
  carries it — avoids serializing a megabyte-scale board DOM on every launch.

## DRY (6A)

- Shared `parseJsonResponse` (endpoint.js ↔ bulk-endpoint.js) — one tolerant JSON parser.
- Shared `splitPathname` primitive (extractors/base.js ← bulk-context.js).
- New `graphqlOp(url) → {op, variables}`; `matchesScope` now JSON-parses the `variables`
  blob instead of substring-matching the raw URL (robust to ordering / encoding).

## Test backfill

- **9A** — `bulk-controller-bootstrap.test.js` (fake `win`/`chromeApi`): START dispatch,
  non-START ignore, double-registration guard, transport-error reply, + the 1A/7A cases.
  `popup-view.js` extracted (`sweepLabel`/`terminalMessage`/`launchOutcome`) and pinned.
- **10A** — engine concurrency: in-flight ≤ MAX_CONCURRENCY, halt-under-concurrency never
  strands an earlier item, jitter uses `random()`.
- **11A** — `bulk-twitter-integration.test.js`: real `x-bookmarks` fixture → source →
  engine; the 075/076 folder-replay contamination sim (never committed before) now lives
  in the suite; the 2A stall→resumable path.
- **12A** — complete-throws vs remove-throws close-tail tests; `REASON_MESSAGE`
  completeness.

## Deferred (agreed premature)

- **4A** (whole-account Pinterest scope), **15/16** (scale/throughput). Left as documented
  future directions; thresholds only.

## Files changed

`extension/src/`: bulk-controller.js, bulk-engine.js, bulk-sw.js, sw.js, twitter-source.js,
bulk-twitter.js, bulk-context.js, bulk-endpoint.js, endpoint.js, extractors/base.js,
bulk-pinterest.js, popup.js; **new** media-hosts.js, popup-view.js.
`extension/test/`: **new** bulk-controller-bootstrap.js, popup-view, media-hosts,
bulk-twitter-integration; extended bulk-engine, bulk-controller, bulk-context, bulk-sw,
sw, bulk-twitter, twitter-source, bulk-pinterest.

## Verification

`node --test` — 270 pass / 0 fail. `npm run drift-check` — clean. No live re-capture in
this pass; the X stall→pause and the auth-wall halt still want a real-session confirmation
(see 019 T-notes).

## Migration notes

None. Reload the unpacked extension (and the x.com tab — the MAIN-world hook injects at
`document_start`). The server may now send `caps` on `POST /jobs`; absent caps fall back to
the local defaults, so an older app build is unaffected.

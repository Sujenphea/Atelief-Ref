# 059 — Bulk import: Pinterest driver (Phase 4)

Phase 4 of bulk import ([.docs/018](../.docs/018-bulk-import-plan.md)): the first
concrete `BulkSource` — a Pinterest board driver that walks a board's pins via
Pinterest's own resource API, replaying the opaque `bookmark` cursor page by page
until `-end-`. Pure over an injected `fetchJson`, so it runs against the committed
sanitized fixtures with no network. Decision 9A / seam A2, taxonomy/skip from Phase 3.

## Summary

- **`bulk-pinterest.js` (new).** SW-side driver — no MAIN-world hook (unlike X): a
  `credentials:'include'` fetch carries the session, with runtime-scraped
  `X-APP-VERSION` + the `csrftoken` cookie authorizing `/resource/…`.
  - `mapPinterestPin(pin, { host, cursor })` → a `BulkItem` (or `null` for a pin
    with no id / no image, so a doomed item is never enqueued). Reuses `base.js`
    `toOriginals()` + the new `makeProvenance()`. Prefers the `orig` image, keeps the
    largest sized variant as a `/originals/`-404 fallback (same fail-open rule as the
    DOM extractor). `sourceId` = the canonical pin id (dedup/skip key).
  - `parseBoardFeedPage` / `parseBoardsPage` — unwrap `resource_response`, throwing
    `PinterestResourceError` (with the http status) on any non-success (auth 403 /
    server error / malformed).
  - `buildBoardFeedURL` / `buildBoardsURL` / `boardFeedHeaders` — the request
    builders, separately exported + tested so a header/param drift breaks a unit test.
  - `enumerateBoardFeed` — the async-generator paginator: each pin carries **the
    bookmark that requested its page** as its `cursor`, so a checkpointed resume
    re-fetches that page and re-yields its pins (the engine's dedup-skip makes the
    overlap idempotent). Terminates at `-end-`; guards against a repeated bookmark
    (loop) and a run of empty pages.
  - `pinterestBoardDriver({ fetchJson, host })` — binds session context and exposes
    `enumerate(board, { cursor })`, conforming to the engine seam.
- **`base.js` — `makeProvenance()`** (the Phase-2 deferral, now landed): the one
  normalized `Provenance` builder both DOM extractors and bulk JSON mappers emit;
  `mapPinterestPin` is its first consumer.
- **`bulk-engine.js` hardening.** A driver that throws mid-enumeration (a fatal page
  fetch / auth wall) no longer crashes the sweep: `pull()` catches the enumeration
  error, halts gracefully (checkpoint preserved, `status:"halted"`), and surfaces it
  as `result.error`. Discovered while wiring the first real driver.

## Files changed

- `extension/src/bulk-pinterest.js` (new)
- `extension/src/extractors/base.js` (+ `makeProvenance`)
- `extension/src/bulk-engine.js` (graceful enumeration-error halt; `result.error`)
- `extension/test/bulk-pinterest.test.js` (new)
- `extension/test/bulk-engine.test.js` (+ enumeration-error halt test)

## Cursor / resume design

The Pinterest `bookmark` advances per PAGE, not per pin. So each pin's checkpoint
cursor is the bookmark used to REQUEST its page (page 1 → `null`); the engine's
contiguous watermark then only commits a page's cursor once every pin on it is
terminal, and a resume re-fetches that whole page. No pin can be skipped on resume,
and already-ingested pins are dedup-skipped — exact-once without exact checkpoints.

## Deferred (honest scope)

- **`UserPinsResource` and board SECTIONS** — no committed fixture, so building them
  now would be untested speculative code. They plug into the same paginator shape
  when a fixture + a whole-account-scope UI need them.
- **Live-sweep header sufficiency** — Phase-0 recon showed a forged request still
  403'd; the driver sends the known header set, and Phase 4's manual verify (sweep a
  real board) confirms it suffices before we rely on it. If it 403s live, the driver
  escalates to capturing headers from a real intercepted request (the X posture).
- **Video pins** — the driver maps a video pin's POSTER image (with `isVideo` flagged
  in provenance); pulling the MP4 in a bulk sweep stays opt-in per the design
  (`resolveVideo` default-off), a later enhancement.

## Verification

`npm test` green — 120 tests (98 pre-existing unchanged + 22 new): the image picker,
id/provenance mapping, video + no-image edge cases, the page parser (success / error
/ end sentinel), URL + header builders, the paginator (multi-page walk, resume,
`-end-` termination, loop guard, empty-page tolerance), boards enumeration, a full
Pinterest-driver × engine sweep, and the graceful driver-failure halt.

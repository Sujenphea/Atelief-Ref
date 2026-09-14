# 471 — one cover is what a board row has

## Summary

[098](../.docs/098-rednote-sweep-plan.md) T2 — `extension/src/bulk-rednote.js`, the
pure board-feed parser. No browser API, no fetch: the board feed is intercepted,
never requested, because rednote signs every call with a URL-derived `X-s` and a
hand-signed request was refused with HTTP 461. The page signs; we parse.

**One `BulkItem` per NOTE, keyed by `note_id`, carrying the cover.** Doc 020 planned
a per-carousel-image fan-out from this response. That data is not in it: a feed row
has nine keys and a single `cover` — `imageList`, `video` and `stream` appear zero
times. Carousels and video need a per-note detail fetch, which is K3b.

## What the live capture forced

- **`cover.url` is `""` on 37/37 rows**, and so is `cover.file_id`. The usable URLs
  are `url_pre`, `url_default` and `info_list[]` (`WB_PRV` / `WB_DFT`). A mapper
  reaching for the obvious field would drop every item as "no usable image", which
  is why selection runs through a `firstNonEmpty` that treats `""` as absent.
- **The terminator is `{ has_more: false, notes: [], cursor: "" }`.** An empty
  cursor ends the feed even when `has_more` is still true — Instagram's
  `next_max_id != null` idiom would read `""` as live and page forever.
- **The author field has two spellings**: `nick_name` in the feed, `nickname` in
  note detail. One `rednoteAuthor` reads both, because reading one yields a silent
  null author on the other surface and nothing fails loudly enough to notice.
- **The request URL arrives protocol-relative** (`//webapi.rednote.com/…`), which
  `new URL()` rejects unaided. Every URL reader takes a base for that reason alone.
- **The matcher is pinned to the PATH**, not a host: the live probe showed rednote's
  own telemetry on adjacent hosts the page also calls (`t2.rnote.com/api/v2/collect`,
  `apm-fe.rnote.com/api/data`, `as.rednote.com/api/sec/v1/shield/webprofile`).

## Two judgement calls

**The token does not enter provenance.** `xsec_token` is a short-lived per-note
credential K3b needs during a sweep and nothing needs afterwards. It rides as a
LOCAL `BulkItem` field beside `cursor`, never inside `provenance` — the same rule
the single-capture path already applies by stripping it from the permalink. A test
asserts it cannot be found anywhere in the serialized provenance.

**The challenge detector is biased toward halting.** The hook forwards responses
status-blind, so a 461 arrives as a body alone — and the observed one was
`success: true, code: 0, msg: ""` where every genuine response says `成功`: a
rejection wearing a success shape. The load-bearing check is therefore the presence
of a real `data.notes` ARRAY, not the status fields. A genuine exhausted feed passes
it (`notes: []` is an array). A false halt costs a resume; a false continue keeps
hammering a session rednote has already flagged.

## Files changed

- `extension/src/bulk-rednote.js` (new) — 11 exports, all pure.
- `extension/test/bulk-rednote.test.js` (new) — 28 tests. The 12 that assert against
  the live capture skip cleanly on a clone that lacks it (it is gitignored until T4
  sanitizes it into a committed fixture) rather than failing.

## Verification

`npm test` 667 → 695 total, 692 pass, 0 fail. `npm run drift-check` clean.

## Migration notes

None. Nothing imports this module yet — the hook, manifest and controller wiring is
T3, and the drift canary plus the sanitized fixture are T4.

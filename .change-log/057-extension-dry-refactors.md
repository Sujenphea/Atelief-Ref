# 057 — Bulk import: extension DRY groundwork (Phase 2)

Phase 2 of bulk import ([.docs/018](../.docs/018-bulk-import-plan.md)): the
extension-side refactors the bulk engine (Phase 3) and drivers (Phase 4–5) build
on. Behaviour-preserving — single-item capture is byte-for-byte unchanged.
Decisions 5A / 6A / 8A.

## Summary

- **5A — shared `ingestOne` tail.** Extracted the ingest tail (optional video
  download → fetch bytes → build request → POST → interpret) from
  `sw.js:captureCore` into `ingestOne(provenance, {token, mp4Url, jobId, sourceId},
  deps)`. `captureCore` now does the single-item-specific front (extract + video
  DETECTION using harvest/context) then delegates to `ingestOne`. The bulk engine
  will call `ingestOne` directly with its own `mp4Url` + `jobId`/`sourceId`.
- **6A — shared full-resolution rewrites.** Moved `fullResolution` out of
  `twitter.js` (`name=orig`) and `pinterest.js` (`/originals/`) into
  `extractors/base.js` as `toOrigName` / `toOriginals`; both extractors now reuse
  them, and the bulk JSON mappers (Phase 4–5) will too.
- **8A — `config.js`.** New single-source `config.js` holds `MAX_VIDEO_BYTES`
  (relocated from `sw.js`, killing the hand-synced copy). The video cap is a
  client-side optimisation; the server stays authoritative. A bulk sweep will read
  the server's caps from the `POST /jobs` open response and override.
- **Bulk tagging pass-through.** `buildCaptureRequest` /
  `buildProvenanceHeader` (endpoint.js) + `downloadAndIngestVideo` (sw.js) accept
  optional `jobId`/`sourceId`, emitted on the wire only when present (untagged
  single-item captures send the identical body/header as before).

## Files changed

- `extension/src/extractors/base.js` (+ `toOrigName`, `toOriginals`)
- `extension/src/extractors/twitter.js`, `pinterest.js` (reuse the shared rewrites)
- `extension/src/sw.js` (`ingestOne` split; `MAX_VIDEO_BYTES` via config; video tags)
- `extension/src/endpoint.js` (jobId/sourceId on request + provenance header)
- `extension/src/config.js` (new)
- Tests: `sw.test.js` (+ `ingestOne` suite), `endpoint.test.js` (+ bulk tags),
  `extractors.test.js` (+ `toOrigName`/`toOriginals`).

## Deviation from the plan (deliberate)

Phase 2 planned a shared `makeProvenance` too. **Deferred to Phase 4** on purpose:
the five existing extractors have *heterogeneous* provenance shapes (only
twitter/pinterest carry `mediaUrlFallback`; cosmos/instagram/web don't), so forcing
a uniform `makeProvenance` now would change three extractors' output and touch code
with no current consumer. `makeProvenance` will land in `base.js` alongside the
first bulk JSON→provenance mapper that actually needs it (6A intent preserved,
premature-abstraction avoided).

## Verification

`npm test` green — 79 tests (70 pre-existing unchanged + 9 new). Single-item
capture behaviour identical (the full `captureCore` branch matrix still passes).

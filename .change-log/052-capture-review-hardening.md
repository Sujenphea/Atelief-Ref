# 052 — Capture extension + endpoint: review hardening

## Summary

An interactive four-section review (Architecture → Code Quality → Tests →
Performance) of the Atelier Capture extension + localhost endpoint, followed by
the agreed fixes. Every issue was decided by the user; the plan lives at
`~/.claude/plans/review-this-plan-thoroughly-soft-bear.md`. This is hardening +
test coverage — no behaviour change to a successful capture. Highlights:

- **Cross-language wire contract is now pinned** by a shared fixture both suites
  read (a field rename on either side breaks a test).
- **Every outbound SW fetch has a timeout** — a hung CDN no longer wedges a
  capture with no feedback.
- **The service-worker orchestration is now unit-tested** (was manual-only), and
  its video-path error handling distinguishes expected from unexpected failures.
- **Two performance fixes**: chunked base64 (no more multi-second jank on large
  images) and first-video-only JPEG rasterization (light captures on busy feeds);
  video uploads stream from a `Blob` instead of a full in-memory `Uint8Array`.
- **Server request/outcome logging** for observability.

Three reviewed items were deliberately **no-code** (see Decisions below).

## What changed

### Extension (`extension/`)

- **`src/net.js` (new) — `fetchWithTimeout` (3A).** One AbortController wrapper
  (15 s default) now used by every SW fetch: image, video download,
  `resolveTwitterVideo`, `resolvePinterestVideo`. A stalled socket becomes a clean
  rejection the caller falls back from.
- **`src/sw.js` — extracted an injectable core (9A) + error/perf fixes.** The
  capture flow (`captureCore`), `fetchImage`, `downloadAndIngestVideo` and
  `presentation` are now pure/injectable functions; the `chrome.*` listeners are a
  thin glue shell guarded by a `typeof chrome` check so the module imports under
  `node --test`. Also: **8A** — the video path splits an EXPECTED failure
  (not a video / resolution failed → quiet `log`) from an UNEXPECTED one (a
  resolved video that fails to download/ingest → loud `logError`), both still
  falling back to the still image; `contextMenus.create` is now preceded by
  `removeAll()` (no duplicate-id throw on update); a stale badge is cleared at the
  start of each capture. **13A** — `bytesToBase64` encodes in 32 KB chunks
  (`String.fromCharCode.apply`) instead of per-byte concat. **15A** —
  `downloadAndIngestVideo` POSTs a `Blob` (browser-backed, streamed) rather than a
  materialized `Uint8Array`.
- **`src/harvest.js` — split into an in-page reader + a pure shaper (10A + 14A).**
  `harvestSignals` (injected, self-contained) now returns a RAW snapshot and
  rasterizes ONLY the first eligible `<video>` frame, as JPEG (was: every video,
  as PNG). The new pure, exported `buildHarvest(raw)` does the meta-dedup + media
  `kind` classification + skip rules the extractors consume — the SW calls it on
  the injected result. The harvest object the extractors receive is unchanged.
- **`src/endpoint.js` — DRY (6A) + Blob (15A).** Extracted `normalizeProvenance(p)`
  (the single JS wire-shape authority, used by `buildCaptureRequest` +
  `buildProvenanceHeader`) and `parseJsonResponse(response)` (shared by
  `postCapture` + `postVideoCapture`). `postVideoCapture` accepts a `Blob`.
- **`src/twitter-video.js` — explicit token derivation (7A).** Extracted
  `deriveSyndicationToken(tweetId)`, `36` instead of `6 ** 2`, with a comment that
  it mirrors Twitter's own (lossy `Number()`) formula.

### Server (`AtelierServer/`)

- **`CaptureServer.swift` — request/outcome logging (4A).** `CaptureHTTPHandler`
  logs `method path → status` (`.info`) and rejections (`.warning`) via `os.Logger`
  (`subsystem: so.atelier.capture`). The token, image bytes and provenance are
  never logged. Origin pinning stays deferred (`pinnedExtensionID = nil`) until a
  stable published extension id exists — the token is the real barrier.

### Tests

- **`extension/test/fixtures/capture-contract.json` (new, 1A)** — the canonical
  `CaptureRequest` + video-header shapes. `endpoint.test.js` asserts the extension
  PRODUCES them; `CaptureDecoderTests.swift` (`contractImage`/`contractVideo`)
  asserts the server DECODES them into the matching `SourceDraft`.
- New `extension/test/net.test.js` (timeout/abort) and `extension/test/sw.test.js`
  (the capture branch matrix, the 8A split, `fetchImage` fallback + chunked base64)
  and `extension/test/harvest.test.js` (`buildHarvest` classification).
- Added: the `deriveSyndicationToken` pin (7A), rejected-fetch tests for both POST
  helpers, and Instagram/Cosmos right-click extractor tests (11A).

## Files changed

- `extension/src/net.js` (new), `extension/src/sw.js`, `extension/src/harvest.js`,
  `extension/src/endpoint.js`, `extension/src/twitter-video.js`,
  `extension/src/pinterest-video.js` (wired `fetchWithTimeout`).
- `extension/test/net.test.js` (new), `extension/test/sw.test.js` (new),
  `extension/test/harvest.test.js` (new),
  `extension/test/fixtures/capture-contract.json` (new),
  `extension/test/endpoint.test.js`, `extension/test/twitter-video.test.js`,
  `extension/test/extractors.test.js`.
- `AtelierServer/Sources/AtelierServer/CaptureServer.swift`,
  `AtelierServer/Tests/AtelierServerTests/CaptureDecoderTests.swift`.

## Decisions (no-code)

- **2A — fixed port 47321, no teardown: kept.** Inherent to the single-user /
  single-instance design; a bind collision is already surfaced (status dot +
  extension "is the app running?" badge). No port negotiation added.
- **12A — app-side `onCapture → refresh` wiring left untested.** The risky half
  (off-main ingest + hook firing) is covered by the server's `OnCaptureSpy`; a bug
  in `handleRemoteCapture` mis-refreshes the UI but never loses data.
- **16A — re-capture re-download: accepted.** Byte-hash dedup is correct; the
  alternatives add a weaker second notion of identity for a rare-in-single-user
  bandwidth cost.
- **4A — origin pinning deferred** (not "won't do"): revisit once a stable
  published extension id exists.

## Verification

- `cd extension && npm test` — **69 tests pass** (was 38; +31 across the new
  net/sw/harvest suites, the contract assertions, the token pin, the rejected-fetch
  and Instagram/Cosmos tests).
- `cd AtelierServer && swift test` — **46 tests in 4 suites pass** (was 44; +2
  cross-language contract tests). The 4A logging is compile- + run-verified; log
  output in Console is a manual check.
- Manual end-to-end (app running, extension loaded unpacked) remains the check for
  the real capture round-trip, the JPEG frame on a video tweet/pin, and the
  bind-collision path (2A).

## Migration notes

None — no schema change and no change to a successful capture's wire format
(the contract fixture encodes the existing shape). The extension's harvest data
flow changed internally (`harvestSignals` returns a raw snapshot; the SW calls
`buildHarvest`), but the object the extractors receive is identical, so the
extractors and their tests are untouched. New test files are picked up
automatically (`node --test`; SwiftPM test target).

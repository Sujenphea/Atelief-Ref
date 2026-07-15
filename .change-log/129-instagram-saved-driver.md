# 129 — Instagram saved-posts BulkSource driver (002 · B3)

## Summary

The Instagram saved-posts sweep driver — parser, source, controller wiring, sweep
resolver, pacing, and drift canary. With B0–B2 (fixtures, shared hook-core, host
permission + hook) in place, this makes an IG saved-posts sweep actually run end-to-end.
All pure/injectable, tested against the committed fixture (no live IG). 348 tests green.

## What's new

- **`bulk-instagram.js`** — pure parser. `parseSavedFeedPage(json)` →
  `{ items, endOfFeed, nextMaxId, error }`:
  - **Per-media fan-out (1A):** a carousel → one `BulkItem` per `carousel_media[]` child
    (each keyed by its own `pk`), a single image/reel → one item, via the plain-image
    path (no `content` descriptor) — the Pinterest item shape, so engine dedup-skip works
    per picture. A tombstone / imageless media is dropped.
  - **Reel video (7A):** poster (`image_versions2`, largest-by-width, defensive sort) as
    the card; best `video_versions[]` MP4 stashed in `rawMetadata.videoUrl` so the
    existing resolve-video toggle downloads it — no extra network call.
  - **Challenge recognizer (3A):** `detectChallenge` maps a checkpoint / login /
    rate-limit / bare-`status:"fail"` body → an `InstagramChallengeError` returned as
    `page.error` (never thrown); the source re-raises it so the engine halts RESUMABLE.
  - **Pagination:** `next_max_id` is the checkpoint cursor; `more_available:false` (or
    absent) is end-of-feed.
- **`instagram-source.js`** — thin `createInterceptSource` adapter (mirrors
  twitter-source.js): IG page parser + `InstagramStallError`. No scope matcher needed —
  the hook's URL matcher only forwards the flat saved feed, so there are no other-feed
  pages to drop (collections use a different path, 6A).

## What changed

- **`bulk-controller.js`** — `buildInstagramDriver` (subscribe to the IG hook's messages,
  auto-scroll, replay request; `dispose` removes the listener, 1A); a `SUPPORTED_PLATFORMS`
  set + three-way driver arm; per-platform pacing threaded from `PLATFORM_PACING` (engine
  config to `runBulkSweep`, source timing to the driver).
- **`config.js`** — `PLATFORM_PACING` map (13A): IG sweeps gentler (concurrency 2,
  1500ms + 1200ms jitter, settle 3000ms, 5 idle rounds); X/Pinterest inherit the globals.
- **`bulk-context.js`** — `platformForHost` += instagram; `resolveSweepSpec` IG arm
  (flat `/saved/` + `/saved/all-posts/` → `scope:"saved"`; a specific collection → typed
  `instagram-collection-unsupported`; other IG pages → `instagram-not-saved`) + refusal copy.
- **`popup-view.js`** — `sweepLabel` IG arm ("Sweep your Instagram saved posts").
- **`drift.js` / `drift-check.js`** — `checkInstagramSaved` (structural fan-out count via
  IG's declared `carousel_media_count`, video-url extraction, challenge non-misfire, route
  matcher) registered as the `instagram` check; the CLI prints IG's own 14-day stale
  window from its per-platform marker.

## Test results

`node --test`: **348 pass / 0 fail** (+28: 15 parser + 5 integration + IG context/drift
cases). Drift CLI green: `Instagram saved feed — posts=3 items=6 videos=1 endOfFeed=true`.
New coverage: fan-out (image/reel/carousel), poster/video pickers, challenge recognizer
+ mid-sweep resumable halt (11A), stall halt, resolveSweepSpec matrix (flat / collection
refusal / not-saved), drift fan-out/challenge/image invariants.

## Migration notes

None (extension-only, no app or schema change — the per-media fan-out keeps the ledger
platform-generic). Remaining for B4: the popup account-risk warning/acknowledge gate.
Known limitation carried from B0: the mid-feed `next_max_id` cursor is IG-convention (the
recon account was single-page) — the paginating tests synthesize it; re-verify live.

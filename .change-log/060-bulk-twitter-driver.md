# 060 — Bulk import: X / Twitter driver (Phase 5)

Phase 5 of bulk import ([.docs/018](../.docs/018-bulk-import-plan.md)): the X side of
the bulk sweep. Unlike Pinterest (which we paginate ourselves), X's timeline requests
are made BY THE PAGE as it auto-scrolls — the `features`/`queryId`/`x-client-transaction-id`
are too volatile to forge (Phase-0 recon) — so we INTERCEPT the responses instead.
This lands the pure parsing core + the MAIN-world hook. Decisions 4A / 9A / seam A2.

## Summary

- **`bulk-twitter.js` (new) — pure parsers over an intercepted timeline response.**
  - `parseTimelinePage(json)` → `{ items, bottomCursor, tweetCount }`. `tweetCount`
    is the terminator signal (X has no `-end-`; a page with 0 tweet entries is the
    end). Each item is stamped with `bottomCursor` as its checkpoint token.
  - `mapTweet(result)` → **one `BulkItem` per top-level media** (a tweet carries up
    to 4 photos), keyed by the stable `media_key` — NOT the tweet id, which would
    collide and make the engine dedup-skip all but one photo. `originalURL` still
    points at the tweet. Reuses `base.js` `toOrigName()` + `makeProvenance()`.
  - **Video/gif → poster image** (matching the Pinterest driver + the design's
    default-off bulk video), with the best progressive MP4 stashed in
    `rawMetadata.videoUrl` — the URL is already in the timeline response, so a future
    opt-in bulk-video path needs no syndication call. Reuses `twitter-video.js`
    `selectBestVideo()`.
  - **Never reads quoted-tweet media** — only the top-level tweet's
    `extended_entities.media` (a quoted asset belongs to the quoted author, not what
    the user bookmarked). A fixture test pins this.
  - `unwrapTweet` (visibility-wrapper + tombstone handling) and `findInstructions`
    (Bookmarks/Likes wrapper shapes + a bounded deep-search fallback for drift).
- **`twitter-hook.js` (new) — the MAIN-world fetch hook.** Wraps `window.fetch`,
  clones every `Bookmarks`/`Likes` response (`isTimelineRequest`), and forwards it to
  the content script via `postMessage`. Read-only, idempotent, best-effort: a clone +
  fire-and-forget parse that NEVER throws into the page or alters a response. A
  guarded auto-install runs when injected as a MAIN-world script on x.com/twitter.com.
- **`base.js` — `toOrigName(src, { addIfAbsent })`.** The DOM extractor keeps its
  contract (a bare URL is left alone); the bulk mapper passes `addIfAbsent:true`
  because X's timeline JSON gives a bare `media_url_https` and we still want `orig`.
  One helper, two documented contracts — no duplicate rewrite logic.

## Files changed

- `extension/src/bulk-twitter.js` (new)
- `extension/src/twitter-hook.js` (new)
- `extension/src/extractors/base.js` (`toOrigName` gains `{ addIfAbsent }`)
- `extension/test/bulk-twitter.test.js` (new)
- `extension/test/extractors.test.js` (+ `addIfAbsent` case)

## Deferred (honest scope)

- **`manifest.json` wiring** (persistent host_permissions for x/twitter/pinterest +
  the `world:'MAIN'` content-script registration) is deferred to **Phase 6**, where
  the content-script loop that RECEIVES the hook's messages lands — so the manifest
  always references real, working files and the permission prompt appears with the
  feature that needs it, not before. The hook SCRIPT + its auto-install are ready.
- **The push→pull adapter** (an async iterator fed by the intercepted responses as
  the page scrolls, conforming to the engine seam) is the Phase-6 content-script
  loop. Phase 5 delivers the parsing it will call; the seam is `parseTimelinePage`.
- **Fetch-only hook.** X uses `fetch` for GraphQL (Phase-0 recon), so the hook wraps
  `fetch` only — fully unit-testable, no untested XHR patch shipped. If a real
  capture shows a timeline call over XHR, an XHR patch (with a test harness) gets
  added; the manual verify confirms capture first.
- **Likes > ~3,200** (GDPR-archive upload path) stays the design's stretch item.

## Verification

`npm test` green — 132 tests (120 pre-existing unchanged + 12 new): the timeline URL
predicate, tweet unwrap, multi-photo → many-items mapping, video → poster + best-MP4,
the no-quoted-media rule, the page parser (items + bottom cursor + tweetCount +
empty-timeline terminator), `findInstructions` drift fallback, and the MAIN-world
fetch hook (forward / pass-through / idempotent / never-break-the-page).

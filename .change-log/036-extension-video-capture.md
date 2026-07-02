# 036 — Extension: download the actual Twitter video (video capture, checkpoint E)

The extension now saves a video tweet as the real MP4 (not just a keyframe).

## Flow
- The Twitter extractor flags a video tweet: `mediaKind: "video"` when there's a
  video frame/poster and no still photo (a right-clicked image stays `"image"`).
- On capture, if `mediaKind === "video"` and a `tweetId` is known, the SW:
  1. resolves the tweet's MP4 via the public **syndication API**
     (`cdn.syndication.twimg.com/tweet-result?id=…`), picking the highest-bitrate
     `video/mp4` variant (`src/twitter-video.js`),
  2. downloads the MP4 in-session, and
  3. POSTs the raw bytes to `/ingest-video` with provenance in the
     `X-Atelier-Provenance` header (base64 JSON via `buildProvenanceHeader`).
- **Graceful fallback**: any failure (resolution, fetch, or a non-200 ingest)
  falls through to the existing image path — the on-screen `<canvas>` frame, else
  the poster — so a video capture is never worse than before.

No manifest change: `*://*.twimg.com/*` already covers `cdn.syndication.twimg.com`
and `video.twimg.com`.

## Tests (`node --test` → 30/30)
- `twitter-video.test.js` (new): highest-bitrate-MP4 selection across payload
  shapes, HLS/photo-only → null, syndication URL, mocked resolve (ok / 404 /
  no-mp4).
- `endpoint.test.js`: `base64Utf8` UTF-8 round-trip, `buildProvenanceHeader`
  shape (drops collectionId + client-only `mediaKind`), `postVideoCapture`
  octet-stream + headers.
- `extractors.test.js`: `mediaKind` video/image/right-clicked cases.

## Caveat (needs manual verification)
The syndication `token` is derived by a formula that is Twitter's, not ours — if
Twitter changes it, resolution fails and the extension falls back to the poster.
The live fetch is not unit-tested (walled session); the `[Atelier] fetched video`
/ `ingest-video response` logs make a live run diagnosable from the SW console.

## Files changed
- `src/twitter-video.js` (new), `src/endpoint.js` (video POST + base64),
  `src/extractors/twitter.js` (mediaKind), `src/sw.js` (video branch + fallback),
  `test/twitter-video.test.js` (new), `test/endpoint.test.js`,
  `test/extractors.test.js`, `README.md`.

# 039 — Extension: capture actual Pinterest videos (video capture)

## Investigation (real, not guessed)
The user reported two "video not captured" cases; I verified each against real data
before changing anything:
- Pin `2111131073714393` — NOT a video. Pinterest's own data: `"videos":null`; no
  video URL on the page. The extension correctly saved the image. No bug.
- Pin `1030339221009481451` — a REAL video pin (`"videos":{"videoUrls":[…]}`). The
  extension had **no Pinterest video path** (only Twitter), so it saved the
  `<video>`'s poster (`i.pinimg.com/…`). Confirmed root cause.

## How Pinterest exposes video (verified live)
- The live (logged-in) DOM `<video>` has an HLS `.m3u8` src (not ingestable) + an
  `i.pinimg.com` poster; the progressive MP4s are NOT in the SPA DOM.
- The progressive MP4s (`v1.pinimg.com/videos/iht/…`) live in the pin page's
  server-rendered `"videoUrls":[…]` — but ONLY on the **logged-out** SEO HTML; a
  logged-in request returns a shell without them. The PinResource JSON API is 403
  without a CSRF token.

## Implementation
- `src/pinterest-video.js` (new): `resolvePinterestVideo(pinId)` fetches the pin
  page **cookie-less** (`credentials: "omit"` — load-bearing, else the shell) and
  `selectBestVideo` picks the best progressive MP4 (H.264 `/expMp4/` preferred over
  HEVC, then largest `_<N>w`; HLS/DASH skipped).
- `src/harvest.js`: also records a non-blob `<video>` src as `video-src` — a robust
  "this is a video" signal.
- `src/sw.js`: unified video branch — Twitter (syndication) OR Pinterest (pin-page,
  gated on a harvested video signal so image pins skip the ~1 MB fetch); shared
  `downloadAndIngestVideo`. Falls back to the image path on any failure.
- `manifest.json`: `*://*.pinterest.com/*` host permission (v1.pinimg.com MP4s are
  already covered by `*.pinimg.com`).

## Verification (end-to-end, real pin)
- Cookie-less fetch (SW-equivalent) → `extractVideoUrls`/`selectBestVideo` →
  `…/expMp4/…_720w.mp4` → downloaded 362,588 bytes → header `ftypisom` (a valid
  MP4; `isom` is exactly what the server's `MediaProbe` accepts as `video/mp4`).
- `node --test` → **37/37** (+7 Pinterest: selection incl. H.264-preference &
  HEVC-fallback, `videoUrls` extraction, the video gate, cookie-less resolve).

## Files changed
- `src/pinterest-video.js` (new), `src/harvest.js`, `src/sw.js`, `manifest.json`,
  `test/pinterest-video.test.js` (new), `README.md`.

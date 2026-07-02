# 032 — Extension: capture the live video frame on Twitter (build-order #6)

Follow-up after 031: on a **video** tweet, capture landed on Twitter's video
poster — a keyframe Twitter chose — rather than the frame the user is looking at.

## Root cause (not a bug — a limitation)
A video tweet has **no still image on the server**. Twitter exposes only the
poster (`pbs.twimg.com/ext_tw_video_thumb/…`), so the extractor correctly fell to
it (there's no `pbs.twimg.com/media/` photo to prefer). "The actual image" the
user wants — the frame on screen — exists only client-side, in the `<video>`
element.

## Fix — grab the on-screen frame via `<canvas>`
`harvest.js` now, for each `<video>`, draws the **current** frame to a canvas and
emits it as a `video-frame` media source (a `data:image/png` URL), *before* the
poster. The Twitter extractor prefers it over the poster and keeps the poster as a
network fetch fallback.

- **Two guarded fallbacks** (degrade to today's poster behaviour):
  - a frame is only captured when one is decoded (`readyState >= HAVE_CURRENT_DATA`
    and `videoWidth/Height > 0`) — an un-played video yields no frame;
  - `toDataURL()` is wrapped in try/catch, so a cross-origin-tainted canvas
    (`SecurityError`) is skipped rather than throwing.
- The data-URL frame flows only as a **fetch candidate** — the SW `fetch()`es it
  natively (data URLs are supported), so no special-casing in the fetch/POST path;
  it never enters the POST body (only the resulting base64 does), and
  `fullResolution()` leaves data-URLs untouched.
- SW capture log summarizes the multi-MB data-URL (`data:image/png;base64,…(N chars)`)
  instead of dumping it.

## Media priority (Twitter), unchanged except for the new frame step
right-clicked image → focused tweet photo (`media/`) → **live video frame** →
video poster → `og:image`.

## Verification
- `extension/`: `node --test` → **19/19** (added: frame-wins-with-poster-fallback,
  no-decodable-frame→poster, real-photo-still-beats-frame).

## Files changed
- `extension/src/harvest.js` (canvas frame grab), `src/extractors/base.js`
  (`firstMediaOfKind`), `src/extractors/twitter.js` (prefer frame; skip data-URL
  rewrite), `src/sw.js` (`logSafe`), `test/extractors.test.js`, `README.md`.

## Note
Reload the unpacked extension. On a video tweet, **let the frame you want be on
screen** (play/scrub to it), then right-click → Save to Atelier — you'll get that
exact frame at native resolution. An un-played video falls back to the poster.

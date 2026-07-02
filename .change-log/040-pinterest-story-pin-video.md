# 040 — Extension: Pinterest story/idea pin video (video capture)

## Bug (real, verified)
Pin `993536367811560951` — a video — still saved only the image after 039.
Root cause, confirmed against the real page: it's a **story / idea pin**
(`"storyPinData":{…}`, top-level `"videos":null`). Its MP4s exist
(`v1.pinimg.com/videos/iht/expMp4/…_720w.mp4`, verified `200 video/mp4`) but are
nested under `storyPinData` — NOT in the `"videoUrls":[…]` array that 039's
`extractVideoUrls` parsed. So resolution found nothing and fell back to the image.
(The gate fired correctly — the live DOM has a `<video>` with poster + HLS src.)

## Fix
`extractVideoUrls` no longer depends on the `videoUrls` JSON shape: it pulls every
`v*.pinimg.com/videos/…(.mp4|.m3u8|.mpd)` URL from the pin's server HTML (deduped),
which covers BOTH regular video pins and story/idea pins. The SEO HTML for a pin
carries only that pin's own video(s), so it doesn't grab unrelated media
(confirmed: one distinct video hash on the page). `selectBestVideo` is unchanged
(H.264 `/expMp4/` preferred, largest `_<N>w`).

## Verification (both pin shapes, real pages)
- Generalized extractor + selector on the real HTML:
  - regular pin → `…/expMp4/a3ee…_720w.mp4`
  - story pin  → `…/expMp4/65da…_720w.mp4`
- Full cookie-less chain on the story pin → downloaded 234,855 bytes → header
  `ftypisom` (valid MP4).
- `node --test` → **38/38** (+1: story-pin extraction).

## Files changed
- `src/pinterest-video.js` (generalized `extractVideoUrls`),
  `test/pinterest-video.test.js`.

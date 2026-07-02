# 038 — Extension: fix Twitter video never triggering (video capture)

## Bug
On a real video tweet the extension captured the poster, not the video. Verified
live: the syndication API + MP4 selection + fetch all work (the 1080p MP4 resolves
and 200s). The failure was purely the **trigger**.

## Root cause
The video path was gated on `provenance.mediaKind === "video"`, and the extractor
computed `mediaKind` from a DOM heuristic: `hasVideoSignal && !clicked`. When the
user **right-clicks**, `context.srcUrl` is a `pbs.twimg.com` image (the poster), so
`clicked` was truthy → `mediaKind` flipped to `"image"` → the video path was
skipped → the poster was captured.

## Fix
Syndication is the source of truth for "is there a video", so don't rely on the DOM
heuristic. New `shouldResolveVideo(provenance, context)`: try the video path for any
Twitter status with a tweet id, UNLESS the user explicitly right-clicked a `/media/`
photo (respect that still). A non-video tweet simply returns no MP4 variant and
falls back to the image path. Removed the now-dead `mediaKind` extractor field.

## Verification
- Live: `cdn.syndication.twimg.com/tweet-result` with the derived token returns the
  variants; `selectBestVideo` picks the 1080×1920 MP4; the MP4 HEADs 200
  `video/mp4`.
- `node --test` → **30/30** (added `shouldResolveVideo` cases incl. the
  right-clicked-poster regression; removed the `mediaKind` test).

## Files changed
- `src/twitter-video.js` (+shouldResolveVideo), `src/sw.js` (use it),
  `src/extractors/twitter.js` (drop mediaKind), `test/twitter-video.test.js`,
  `test/extractors.test.js`.

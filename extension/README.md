# Atelier Capture (Chrome MV3 extension)

"Save as you browse" — captures the current post/pin (image + provenance) from
inside your authenticated browser session and POSTs it to the ref-atelier app's
localhost endpoint (`http://127.0.0.1:47321/ingest`).

## How it works

1. **Right-click the image/pin/post → "Save to Atelier"** (recommended — this
   captures the exact image you point at and its post link). The toolbar button
   also works, but only reliably on a single-post page (a pin page, a tweet page),
   not the feed.
2. The service worker injects a tiny signal harvester into the active tab
   (`src/harvest.js`) — meta tags, canonical link, title, URL, and the DOM media.
3. A pure per-site extractor (`src/extractors/*`) turns those signals (plus the
   right-clicked element) into provenance (platform, author, title, media URL, ids).
4. The service worker fetches the image bytes **in your session** (so auth-walled
   media works), base64-encodes them, and POSTs to the app with your token.
5. The app ingests through the same pipeline as paste/drag; a badge shows the
   result (✓ saved / already saved / no image / error).

Supported sites: Twitter/X, Pinterest, Instagram, Cosmos, plus a generic
Open-Graph fallback for any other page.

**Video posts are saved as the actual video** (the app renders a poster tile you
can open to play). The service worker resolves the downloadable MP4 per platform,
downloads it in-session, and POSTs it to `/ingest-video`:
- **Twitter/X** — the tweet's MP4 via the public syndication API (by tweet id).
- **Pinterest** — the pin's MP4, parsed from the pin page's `videoUrls` (fetched
  cookie-less by pin id — a logged-in request returns a shell without them). Only
  triggered when the page actually shows a video, so image pins skip the fetch.

If MP4 resolution fails (e.g. a platform changes its API), it falls back to
capturing a still — for Twitter the on-screen `<canvas>` frame if the video has
been played, else the poster thumbnail.

## Install (unpacked, for development)

1. Open `chrome://extensions`, enable **Developer mode**.
2. **Load unpacked** → select this `extension/` directory.
3. In the ref-atelier app: toolbar → **Browser Capture** → **Copy** the token.
4. Extension → **Details** → **Extension options** → paste the token → **Save**.
5. Make sure the app is running (the endpoint only listens while it's open), then
   browse to a post and click **Save to Atelier**.

## Tests

```
cd extension && npm test      # node --test, no dependencies
```

Unit tests cover the per-site extractors (against saved harvest fixtures) and the
endpoint request/response contract. The service-worker glue (`sw.js`) and the
localhost round-trip are verified manually (see the app's plan / changelog).

## Notes / limitations (MVP)

- The app must be running to capture (no background/offline queue).
- Media fetching is scoped to the known CDN hosts in `manifest.json`
  `host_permissions`; broaden per platform as needed.
- Extraction is Open-Graph-first; richer per-site DOM extraction is Phase 2.

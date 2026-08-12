# Atelier Capture (Chrome MV3 extension)

"Save as you browse" — captures the current post/pin (image + provenance) from
inside your authenticated browser session and POSTs it to the ref-atelier app's
localhost endpoint (`/ingest`).

The port is discovered, not assumed: the stable app listens on **47321** and a
dev build on **47322** (299), so the extension probes `/health` on each and uses
whichever answers, preferring stable when both are up. Pin one explicitly in the
extension's options if you run both at once.

## How it works

1. **Right-click the image/pin/post → "Save to Atelier"** — this captures the
   exact image you point at and its post link. (The toolbar button no longer
   single-captures; it opens the **bulk-sweep popup** — see below.)
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

## Bulk sweeps (toolbar popup)

Clicking the **toolbar button** opens a popup that sweeps the whole feed you're
looking at — X bookmarks (incl. bookmark folders), X likes, or one of your own
Pinterest boards — into the app. The sweep runs in the page (it survives the
service worker being torn down), paces itself, skips already-known items, and
checkpoints so it can resume. Progress, pause/resume, and cancel live in the
app's **Sweeps** tab. Pages that aren't a sweepable feed show a refusal with
the reason.

**Video posts can be saved as the actual video** (the app renders a poster tile you
can open to play) — tick **"Download full video"** in the popup. It is OFF by
default, so a plain sweep saves the poster still. With it on, the service worker
resolves the downloadable MP4 per platform, downloads it in-session, and POSTs it
to `/ingest-video`:
- **Twitter/X** — the tweet's MP4 via the public syndication API (by tweet id).
- **Pinterest** — the pin's MP4, parsed from the pin page's `videoUrls` (fetched
  cookie-less by pin id — a logged-in request returns a shell without them). Only
  triggered when the page actually shows a video, so image pins skip the fetch.

If MP4 resolution fails (e.g. a platform changes its API), it falls back to
capturing a still — for Twitter the on-screen `<canvas>` frame if the video has
been played, else the poster thumbnail.

### What an X sweep saves per tweet

A tweet fans out to one asset per image/video, all sharing the tweet's permalink,
which is how the app groups them into a single tile. Beyond that:

- **Reposts** unwrap to the original — its media, text, author and permalink are
  what get saved, so a repost dedups against a direct save of the same tweet. Who
  reposted it survives as `rawMetadata.repostedBy` (a plain repost adds no words of
  its own; the handle is the whole of what it adds).
- **Quotes** save *both* halves. The title is the quoter's words followed by the
  quoted byline and text; the media are the quoter's own followed by the quoted
  tweet's, all under the quoter's permalink so they group as one post. Media
  borrowed from a quoted tweet get a `<quotingTweetId>:<mediaKey>` source id, so
  bookmarking both the quote and the tweet it quotes saves both in full (the app is
  content-addressed — one blob on disk, two assets).
- **Threads** expand: a bookmarked tweet that belongs to a self-thread is replaced
  by the whole chain, each tweet its own item, all sharing the FIRST tweet's
  permalink and running one continuous index so the tile opens in reading order.
  See below.

### Thread expansion (X)

The bookmarks timeline returns one tweet; the rest of a thread has to be asked for
via `TweetDetail`. Nothing about that request is hardcoded:

- the **`features` blob** and the **auth headers** are inherited from a timeline
  request the page itself just made (the MAIN-world hook forwards an allowlisted set
  of request headers alongside the response — they never leave the tab);
- only the **`queryId`** can't be inherited (TweetDetail has its own, and they
  rotate every 2–4 weeks), so it is scraped from X's own `api.*.js` bundle. A
  content script can't fetch `abs.twimg.com` under the page's CORS, so the service
  worker fetches it under `host_permissions` — host-allowlisted, https-only.

A features drift is self-repairing: X answers a missing flag with a 400 that *names*
the flags it wanted, so the request is retried with them on (bounded, twice).

The chain is reconstructed by walking `in_reply_to_status_id_str` up to the head and
down its continuations — not by filtering on author + conversation id, which would
also sweep in the author's replies to other people's comments.

Every failure here degrades to "save the one tweet we already have": a rotated
queryId, a moved bundle, a rate-limit, a protected conversation. Expansion is a
bonus, never a blocker.

**Cost.** A tweet that starts a thread looks identical to a lone tweet in the
timeline, so the sweep probes: one `TweetDetail` per bookmarked tweet that has any
replies (tweets with none are screened out for free, and each conversation is
fetched once per sweep). These are a second request stream the engine's item pacing
doesn't cover, so they carry their own paced, jittered gap
(`THREAD_PACING_MS` in `config.js`).

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

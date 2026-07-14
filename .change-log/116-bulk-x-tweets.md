# 116 — Bulk X sweep → tweets (003 · C3 · the big payoff)

The bulk X/Twitter sweep now imports **tweets**, not bare images. Each swept tweet
lands as one first-class `tweet` item (kind + payload) carrying its whole media
list as references and its first photo as the card image — the same content path
single-capture already uses (115), now driven by the bulk engine. Pure JS +
node-test; the Swift boundary (113/114) already receives bulk-tagged content
captures unchanged (verified — see Migration notes).

## Decisions (confirmed at kickoff)

- **One tweet = one item.** A multi-photo tweet no longer imports as N separate
  image assets; it collapses to ONE tweet keyed by tweet-id, first photo as the
  card, the rest as `media[]` URL references. (Reduction from the old N-images,
  chosen for the mymind-style "a tweet is one card" model.)
- **Grouping in `mapTweet`.** The full media list only exists inside the timeline
  parser, so grouping moved there (one `BulkItem` per tweet), not at the relay seam.
- **Text-only tweets included** — the broadest coverage: a tweet with no media
  becomes a media-less text-card item (a NEW no-image bulk path).
- **Video opt-in unchanged.** With the video opt-in ON, a video tweet still ingests
  as a video asset (the `mp4Url` → `ingestOne` precedence wins over `content`); OFF
  (default) it lands as a tweet with its poster card. No regression.

## What ships

- **`endpoint.js`** — extracted `buildTweetPayload({ tweetID, mediaUrls, text,
  authorHandle, authorName })`, the ONE tweet-payload builder shared by single-capture
  (`tweetContent`, now a thin adapter over it) and the bulk sweep (a tweet's whole
  media list). `buildContentCaptureRequest` now OMITS the `image` key when there are
  no bytes → the server's media-less `.content` (text-card) path; with bytes it stays
  the hybrid `.contentWithImage` path.
- **`bulk-twitter.js` `mapTweet`** — returns ONE `BulkItem` per tweet (`sourceId` =
  tweet-id, replacing the per-media `media_key` keying), carrying a `content`
  descriptor with all top-level media in `media[]`, the first media as the card image
  (`mediaUrl`), and the first video's progressive MP4 stashed for the opt-in. A
  text-only tweet maps to a media-less item; an empty tweet (no text AND no media) is
  skipped. X never mixes photos and video in one tweet, so "first media" is unambiguous.
- **`ingestOne` (`sw.js`)** — a media-less content branch: when a `content` descriptor
  is present and there is genuinely NO media URL, POST kind+payload with no image. It
  fires ONLY on a truly absent URL — a fetch FAILURE still surfaces as `fetch-error`,
  so a 401/403 auth wall halts the sweep rather than silently downgrading a picture
  tweet to a text card. The post/classify tail is now one shared block (DRY) with the
  request built by branch.
- **Relay threading** — `bulk-controller.js` includes `content: item.content` in the
  `BULK.relay` message; `bulk-sw.js` forwards `message.content` into `ingestOne`. The
  SSRF host allowlist is unchanged (a text-only tweet has no media URL → nothing to
  block). Pinterest items have no `content` → the plain image path, unchanged.
- **`drift.js` `checkTimeline`** — the canary no longer requires every item to carry a
  media URL (a text-only tweet legitimately has none); it now checks each item has a
  tweet-id and that the total media-reference count is non-zero (a real media-shape
  drift → 0). `mediaItems` signal = media references (still 4 on the fixture).

## Files changed

- `src/endpoint.js` (`buildTweetPayload`, `tweetContent` adapter, null-image content body).
- `src/bulk-twitter.js` (`mapTweet` per-tweet), `src/sw.js` (`ingestOne` media-less
  branch + DRY tail), `src/bulk-controller.js` + `src/bulk-sw.js` (thread `content`),
  `src/bulk-engine.js` (BulkItem doc), `src/drift.js` (`checkTimeline` invariant).
- Tests: `test/endpoint.test.js` (+4: `buildTweetPayload` matrix, null-image body),
  `test/sw.test.js` (+2: media-less content post, fetch-failure NOT downgraded),
  `test/bulk-sw.test.js` (+2: content threading, text-only SSRF-passes), rewrites in
  `test/bulk-twitter.test.js` (per-tweet mapping), `test/bulk-twitter-integration.test.js`
  + `test/twitter-source.test.js` (tweet-id sourceIds).

## Tests

Extension **289** green (`node --test`). Drift CLI passes the committed X fixture
(`tweetCount=3 mediaItems=4 hasCursor=true`). No Swift change.

## Migration notes

- **No Swift change, no schema change.** The server's `/ingest` already routes
  `.content` and `.contentWithImage` through the same coordinator with `jobId`/`sourceId`
  → `recordJobItem` (CaptureRoutes.swift:85-106, 151), so bulk-tagged tweet captures
  (with and without a card image) record ledger job-items exactly like image captures.
  This is the FIRST exercise of a content capture carrying bulk tags; verified by
  reading the routing.
- **Behavior change for existing users:** a re-sweep imports tweets, not images. A
  tweet previously bulk-imported as an image (kind=image) does NOT dedup against the new
  tweet (dedup is `(kind, tweet-id)`), so it re-imports as a tweet; the old image
  remains until removed. A multi-image tweet stores only its first image as a blob (the
  card); the other images live as `media[]` URL references until a backfill exists.

## Remaining (003)

- **Multi-image backfill** — the non-card `media[]` references aren't stored as blobs.
  C2b's resolver could backfill them; until then a multi-image tweet shows one card.
- **Single-capture of a text-only tweet** still returns "no image" (out of scope — the
  decision covered the bulk sweep; single capture is a separate small follow-on).
- **C2b — link resolver enrichment** (= 001 `PageResolver`, SSRF-hardened) — still the
  deferred security-sensitive piece; unblocks web→link.

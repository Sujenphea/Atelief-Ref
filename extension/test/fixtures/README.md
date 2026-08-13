# Test fixtures

Committed sample payloads for the pure extractor/mapper/driver tests (no network,
no auth). See `.docs/017-bulk-import-design.md` §"Phase 0 — captured live specs".

## Bulk-import driver fixtures (captured 2026-07-03, sanitized)

Derived from real authenticated responses via a Claude-in-Chrome Phase 0 capture,
then **fully sanitized**: every real ID, handle, display name, tweet/pin text, and
media URL was replaced with a synthetic placeholder. **Structure is preserved
exactly** — field names, nesting, and the signals the mappers key on (media `type`,
`video_info.variants`, the `pbs.twimg`/`video.twimg` host split, the `i.pinimg`
size segment for the `/originals/` rewrite). Raw captures live in the gitignored
`/resources/` and are never committed.

| File | Endpoint | Shape captured |
|------|----------|----------------|
| `x-bookmarks.json` | `GET x.com/i/api/graphql/{queryId}/Bookmarks` | `data.bookmark_timeline_v2.timeline.instructions[TimelineAddEntries].entries[]` — trimmed to **3 tweets (1 video, 1 multi-photo, 1 text-only) + Top/Bottom cursor entries**. Media at `…result.legacy.extended_entities.media[]` (`type`, `media_url_https`, `video_info.variants[]`). |
| `x-bookmarks-live.json` (captured 2026-08-13) | same | The **canary's** X capture — see "Two X timeline fixtures" below. 3 tweets (1 video, 1 four-photo, 1 text-only) + Top/Bottom cursors; `tweetCount=3 mediaItems=7`. |
| `pinterest-boards.json` | `GET /resource/BoardsResource/get/` | `resource_response.data[]` boards (`id`, `name`, `url`) + `resource_response.bookmark` cursor. |
| `pinterest-boardfeed.json` | `GET /resource/BoardFeedResource/get/` | `resource_response.data[]` pins (`id`, `images.{size}.url`, `board`, `videos`) + `bookmark` cursor. |
| `instagram-saved.json` (captured 2026-07-15) | `GET instagram.com/api/v1/feed/saved/posts/` | `items[].media` — trimmed to **3 posts (1 image `media_type:1`, 1 reel `media_type:2`, 1 carousel `media_type:8`)**. Per-media `pk` (the fan-out dedup key, 002 · 1A), `image_versions2.candidates[]` (poster), `video_versions[]` (reel), `carousel_media[]` (child media, each its own `pk`). |
| `instagram-saved-page2.json` (captured 2026-07-15) | `GET instagram.com/api/v1/feed/saved/posts/?max_id=…` | A second, richer page: **11 posts → 25 fanned-out items** (an 11-child carousel + 2- and 4-child carousels + 7 reels + 1 image). Stresses large-carousel fan-out; the `?max_id=` request URL **confirms the pagination param**. |

### Two X timeline fixtures, on purpose
`x-bookmarks.json` is **hand-composed**: trimmed to the tweets that exercise specific
mapper rules (quote-merge, a bare quote of a video, a text-only tweet), and its synthetic
ids/urls are asserted **literally** in `bulk-twitter.test.js`,
`bulk-twitter-integration.test.js` and `drift.test.js`. Re-capturing it means rewriting
those assertions — which is why it sat 41 days stale.

`x-bookmarks-live.json` is a **straight live capture**, sanitized and otherwise
untouched, and it is what the canary runs (`FIXTURE.x`). It answers the only question
the canary asks — *does a response X sent today still parse* — and can be replaced
wholesale with a newer capture without touching a single test. `checkTimeline` still runs
over the composed fixture in `drift.test.js`, so both stay covered.

Refresh it by capturing a Bookmarks response, sanitizing it, and overwriting the file +
`markers.xTimeline.capturedAt` in `drift-baseline.json`. Sanitizing must be a
**key-independent sweep on value shape**, not a list of field names: the capture that
produced this file leaked profile-image urls through `avatar.image_url` when the rule was
keyed on `profile_image_url_https`. Audit by checking every leaf string of the original
against the output — what may legitimately survive is schema constants and video
`bitrate`s (load-bearing: the mapper picks the highest-bitrate MP4).

### Drift canary (`npm run drift-check`)
The opt-in canary (`scripts/drift-check.js`, invariants in `src/drift.js`) runs these
fixtures — or a FRESH live capture you saved into the gitignored `resources/` — through
the real parsers and asserts the structural signals the drivers need still exist:
```
npm run drift-check                                   # check the committed fixtures
node scripts/drift-check.js --x ../resources/live-bookmarks.json   # check a live capture
```
Capture date + the markers below live in `drift-baseline.json`; the CLI warns when the
fixtures are stale (> 30d) and exits non-zero on any drift.

### Drift markers (verify live before trusting — see T12 drift canary)
- **X `Likes` queryId** observed `tl9f_I0xyREhFd5KMzuO7w` (2026-07-03); `Bookmarks`
  observed `iblrFnKr6PZUR-dWpfXG6g` (2026-08-13) — each op has its own.
  **queryIds rotate every ~2–4 weeks.**
- **X `TweetDetail` queryId is never hardcoded** — it is scraped from X's own bundle at
  sweep time. Verified live 2026-08-13: `api.*.js` **no longer exists**, the
  operation→queryId table now ships in `main.*.js`, and the scrape found it in the first
  bundle fetched.
- **X `features`** — a ~40-key boolean blob in the request; volatile. Inherited via
  MAIN-world interception, never hardcoded.
- **Pinterest `X-APP-VERSION`** observed `1df0da9` (2026-07-03); required (bogus →
  403); scraped at runtime from an inline `app_version":"…"` script.
- **Instagram transport** verified 2026-07-15 as REST `GET /api/v1/feed/saved/posts/`
  (same-origin, `credentials:'include'`), **not** GraphQL. Request carries
  `x-ig-app-id` + `x-csrftoken` headers, but under O1 interception we never build the
  request — the page does — so no header scrape is needed (contrast Pinterest).

### Known gaps (fill during Phase 4/5)
- No **video-pin** fixture — the captured pin was an image pin (`videos: null`).
  Capture a Pinterest video pin, or synthesize one, to test the video-pin mapper.
- Cursor `value` strings are placeholders (`"Sample text"` / `SAMPLE_CURSOR_TOKEN==`);
  the tests only require non-empty, non-`-end-` — real cursor opacity is not needed.
- **IG pagination: request param CONFIRMED, response cursor still inferred.** Both
  committed captures are terminal pages (`more_available: false`, no `next_max_id`) —
  the account returns its whole saved feed in ≤2 fetches. The **`?max_id=<token>`
  request param is confirmed live** (page 2 was fetched with one — see the fixture
  table), which corroborates IG's `response.next_max_id → request ?max_id=` convention.
  What's still unseen is `next_max_id` **populated in a non-terminal body**
  (`more_available: true`); the paginating test synthesizes that shape. To fully close
  it, capture the FIRST fetch on an account with enough saves that one page doesn't
  return everything, and confirm the response field name is `next_max_id`.

## Other fixtures
- `capture-contract.json` — the single-item capture endpoint contract (pre-existing).

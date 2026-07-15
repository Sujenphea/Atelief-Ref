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
| `pinterest-boards.json` | `GET /resource/BoardsResource/get/` | `resource_response.data[]` boards (`id`, `name`, `url`) + `resource_response.bookmark` cursor. |
| `pinterest-boardfeed.json` | `GET /resource/BoardFeedResource/get/` | `resource_response.data[]` pins (`id`, `images.{size}.url`, `board`, `videos`) + `bookmark` cursor. |
| `instagram-saved.json` (captured 2026-07-15) | `GET instagram.com/api/v1/feed/saved/posts/` | `items[].media` — trimmed to **3 posts (1 image `media_type:1`, 1 reel `media_type:2`, 1 carousel `media_type:8`)**. Per-media `pk` (the fan-out dedup key, 002 · 1A), `image_versions2.candidates[]` (poster), `video_versions[]` (reel), `carousel_media[]` (child media, each its own `pk`). |

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
  has its own queryId. **queryIds rotate every ~2–4 weeks.**
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
- **IG mid-feed cursor NOT observed.** The recon account had a single page
  (`more_available: false`, no `next_max_id`), so `instagram-saved.json` is a
  verified **end-of-feed** page. The paginating shape — top-level `next_max_id` +
  the next request's `?max_id=<token>` param — is IG-private-API convention, **not
  live-observed**; the paginating test case synthesizes it (`more_available: true` +
  a synthetic `next_max_id`), as the X integration test synthesizes timeline pages.
  Re-verify the field name against a multi-page saved feed when one is available.

## Other fixtures
- `capture-contract.json` — the single-item capture endpoint contract (pre-existing).

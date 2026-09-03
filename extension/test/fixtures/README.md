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
| `pinterest-boards-live.json` (captured 2026-08-14) | same | The **canary's** boards capture — a straight live response, 4 boards, terminal (`bookmark: "-end-"`). |
| `pinterest-boardfeed-live.json` (captured 2026-08-14) | same | The **canary's** board-feed capture — a whole live page, `pins=25 mapped=24 hasBookmark=true`. The 25th entry is **not a pin**: Pinterest interleaves `type: "story"` modules (here `story_type: "related_interests_module"`, a "More ideas" card with an 8-char id and no `images`) into `data[]`, and `mapPinterestPin` correctly returns `null` for them. **`mapped` < `pins` is expected, not drift.** |
| `instagram-saved-live.json` (captured 2026-08-14) | `GET instagram.com/api/v1/feed/saved/posts/` | The **canary's** IG capture: 3 whole posts (image / reel / 2-child carousel) lifted byte-for-byte out of a 21-post, 1.84 MB live page, plus `more_available: true` + a populated `next_max_id`. Parses to `posts=3 items=4 videos=3 endOfFeed=false`. |
| `pinterest-boardfeed.json` | `GET /resource/BoardFeedResource/get/` | `resource_response.data[]` pins (`id`, `images.{size}.url`, `board`, `videos`) + `bookmark` cursor. |
| `instagram-saved.json` (captured 2026-07-15) | `GET instagram.com/api/v1/feed/saved/posts/` | `items[].media` — trimmed to **3 posts (1 image `media_type:1`, 1 reel `media_type:2`, 1 carousel `media_type:8`)**. Per-media `pk` (the fan-out dedup key, 002 · 1A), `image_versions2.candidates[]` (poster), `video_versions[]` (reel), `carousel_media[]` (child media, each its own `pk`). |
| `instagram-saved-page2.json` (captured 2026-07-15) | `GET instagram.com/api/v1/feed/saved/posts/?max_id=…` | A second, richer page: **11 posts → 25 fanned-out items** (an 11-child carousel + 2- and 4-child carousels + 7 reels + 1 image). Stresses large-carousel fan-out; the `?max_id=` request URL **confirms the pagination param**. |

### Composed fixtures vs live fixtures
Every platform now has **two kinds** of fixture, and the split is the point.

A **composed** fixture (`x-bookmarks.json`, `pinterest-boardfeed.json`,
`pinterest-boards.json`, `instagram-saved.json`, `instagram-saved-page2.json`) is trimmed
by hand to exercise specific mapper rules, and the unit tests pin it **literally** —
`assert.deepEqual(boards, [{ id: "1000000000000000219", … }])`, `pins.length === 1`,
`bookmark === "SAMPLE_CURSOR_TOKEN=="`. Re-capturing one means rewriting assertions, so
they are **deliberately frozen**. The top-level `capturedAt` in `drift-baseline.json`
records when they were authored and is explicitly **not** a staleness signal — a window
over a file nobody will ever re-capture is a permanently red gate with no action behind it.

A **live** fixture (`*-live.json`) is a straight capture, sanitized and otherwise
untouched, and it is what the canary runs. It answers the only question the canary asks —
*does a response the platform sent today still parse* — and can be replaced wholesale
without touching a single test. Each carries its **own** `capturedAt` + `staleAfterDays`,
and those are what set the canary's exit code.

Instagram made the case plainest: its composed fixture carries **11–13 keys per media**
where the live API sends **108–128**. Running the canary over it proved only that our own
reduction still parsed.

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

### Refreshing a live fixture
```
node scripts/sanitize-capture.js ../resources/<raw>.json ../resources/<clean>.json
node scripts/audit-capture.js    ../resources/<raw>.json ../resources/<clean>.json   # must print LEAKED: 0
```
`sanitize-capture.js` is the sweep described below; `audit-capture.js` is the check that
keeps it honest, and it **exits non-zero on any leak**. Read the `structuralSurvivors` list
every time rather than trusting the count — handles and enums are the same shape, so the
split between "leaked" and "structural" is a triage aid, not a verdict. Then overwrite the
fixture and bump that platform's `capturedAt` in `drift-baseline.json`.

Refresh X by capturing a Bookmarks response, sanitizing it, and overwriting the file +
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
- **X's photo anchor is a live-DOM assumption no fixture can check.** Each of a tweet's
  own photos is wrapped in `a[href*="/status/"]` whose href is
  `/{handle}/status/{id}/photo/{n}`; `harvestSignals` reads it into a per-photo
  `statusId`, and the X extractor drops a focal-article photo naming a DIFFERENT status
  — a quoted tweet's (099 · P11). **No committed fixture can verify the selector**: it is
  a DOM read and this suite has no jsdom (026 · 9A). The evidence for the shape is
  `toStatusPermalink`'s live observation — right-clicking a tweet's image yields
  `…/status/{id}/photo/1` as the context menu's `linkUrl`, which IS that anchor's href —
  plus the `expanded_url`s in `x-thread-detail.json`, X's own per-photo URLs for a
  status. If X stops wrapping photos in that anchor the rule goes QUIET (a quoted photo
  leaks again) rather than dropping the tweet's own, which is the failure direction
  changelog 124 was reverted for choosing the other way round. Re-verify by right-clicking
  a quoted tweet's image and reading the linkUrl.
- **X `TweetDetail` queryId is never hardcoded** — it is scraped from X's own bundle at
  sweep time. Verified live 2026-08-13: `api.*.js` **no longer exists**, the
  operation→queryId table now ships in `main.*.js`, and the scrape found it in the first
  bundle fetched.
- **X `features`** — a ~40-key boolean blob in the request; volatile. Inherited via
  MAIN-world interception, never hardcoded.
- **Pinterest `X-APP-VERSION`** observed `194583e` (2026-08-14), was `1df0da9`
  (2026-07-03) — **it drifted in 42 days**, which is why it is scraped at runtime from an
  inline `app_version":"…"` script and never sent from a constant. Note it is *not* the
  403 trigger (see below); it is app-identifying only.
- **Pinterest `x-pinterest-pws-handler` is presence-checked, not route-matched.**
  Re-probed 2026-08-14: no header → **403**; header present → **200**. `BoardsResource`
  returned 200 for **both** `www/[username].js` and `www/[username]/[slug].js`, so the
  server does not verify the value names the resource being called. `BoardsResource`
  therefore gained a `PWS_HANDLERS` entry (its true route), lifting the deferral on the
  whole-account boards path. Relying on the laxity would be unwise — if Pinterest starts
  matching routes, a wrong value 403s.
- **Instagram transport** verified 2026-07-15 as REST `GET /api/v1/feed/saved/posts/`
  (same-origin, `credentials:'include'`), **not** GraphQL. Request carries
  `x-ig-app-id` + `x-csrftoken` headers, but under O1 interception we never build the
  request — the page does — so no header scrape is needed (contrast Pinterest).

### Known gaps (fill during Phase 4/5)
- **No video-pin fixture, and it is not a matter of capturing harder.** Probed live
  2026-08-14. A board *does* hold pins flagged `is_video: true` — but `videos` is `null`
  on every one of them, across **four** field sets (`react_grid_pin`, `detailed`,
  `unauth_react_main_pin`, `partner_react_grid_pin`) **and** a direct `PinResource` fetch
  for one of those pins by id. So the video payload is not reachable from board-feed data
  on this account at all, and `mapPinterestPin`'s video branch stays unexercised by any
  real response. Filling this needs either a different account/region that does serve
  `videos`, or a synthesized pin — which would be an invented shape, i.e. exactly the
  "never verified against production" state the canary exists to flag. Do not spend
  another session hunting for a board with the right pins in it.
- Cursor `value` strings are placeholders (`"Sample text"` / `SAMPLE_CURSOR_TOKEN==`);
  the tests only require non-empty, non-`-end-` — real cursor opacity is not needed.
- ~~**IG pagination: response cursor inferred.**~~ **CLOSED 2026-08-14.** The saved feed
  had grown past one page, so the first fetch finally came back **non-terminal**:
  `more_available: true` with `next_max_id` populated (a 120-char opaque string). Feeding
  it back as `?max_id=` returned **200 with 21 further posts**, itself still non-terminal.
  Both halves of the `response.next_max_id → request ?max_id=` round trip are now
  confirmed against live data; the field name is no longer taken on convention. The
  paginating unit test still synthesizes the shape, which is fine — it is now synthesizing
  a shape that has been **seen**.

## Other fixtures
- `capture-contract.json` — the single-item capture endpoint contract (pre-existing).

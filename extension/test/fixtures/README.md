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
| `x-bookmarks-live.json` (captured 2026-09-14) | same | The **canary's** X capture — see "Two X timeline fixtures" below. A whole live bookmarks page: **7 tweets** + Top/Bottom cursors; `tweetCount=7 mappedTweets=7 mediaItems=12`. The first X fixture here produced by `sanitize-capture.js` rather than by hand, which is how 498 found two things the sweep had never been asked to survive — see "X's envelope and X's ids" below. |
| `x-thread-detail.json` (captured 2026-09-14) | `POST x.com/i/api/graphql/{queryId}/TweetDetail` | The **canary's** X CONVERSATION capture — a real 28-tweet thread: a 4-tweet self-thread, 27 tweets carrying a parent, 28 with a readable author, mapping to 4 grouped items. The focal tweet arrives as a **bare `TimelineTimelineItem`** and the 27 continuations inside a **conversationthread module**, which is why `collectConversationTweets` walks generically. Three of the four spine tweets carry a `note_tweet` long-form body whose text differs from the TRUNCATED `legacy.full_text`, so the fixture exercises `tweetText`'s precedence. |
| `pinterest-boards.json` | `GET /resource/BoardsResource/get/` | `resource_response.data[]` boards (`id`, `name`, `url`) + `resource_response.bookmark` cursor. |
| `pinterest-boards-live.json` (captured 2026-09-14) | same | The **canary's** boards capture — a straight live response, 4 boards, terminal (`bookmark: "-end-"`). |
| `pinterest-boardfeed-live.json` (captured 2026-09-14) | same | The **canary's** board-feed capture — a whole live page, `pins=25 pinEntries=25 mapped=25 hasBookmark=true`. The 2026-08-14 page put 24 of its pins inside ONE `type: "story"` module and this one puts all 25 in `data[]` as bare pins, so `modules` went 1 → 0 and `mapped` now equals `pins`. **Both shapes are normal**; `mapPinterestPin` returns `null` for a story module, so `mapped` < `pins` is expected on a page that has one, not drift. |
| `instagram-saved-live.json` (captured 2026-09-14) | `GET instagram.com/api/v1/feed/saved/posts/` | The **canary's** IG capture, and now **the whole page**: all 21 posts (7 reels, 14 carousels; 108–128 keys per media) rather than the three the 2026-08-14 fixture kept, plus `more_available: true` + a populated 120-char `next_max_id`. Parses to `posts=21 items=118 videos=38 endOfFeed=false`. This is the capture that found the composite-id hole — see below. |
| `rednote-board-live.json` (captured 2026-09-13) | `GET //webapi.rednote.com/api/sns/web/v1/board/note?board_id=…&cursor=…` | The **canary's** rednote capture — a whole live board page, `notes=37 items=37 hasMore=true`. A middle page: `num=30` returned **37** notes (page size is not honoured) and the next `cursor` is literally the **last row's `note_id`**. Rows carry ONE `cover` — no `imageList`, no `video`, no `stream` — which is why K3a fans out one item per **note**. `cover.url` and `cover.file_id` are `""` on **37/37**, so `url_pre` / `url_default` / `info_list[WB_PRV\|WB_DFT]` are the only usable urls. |
| `rednote-board.json` | same | The **composed** board page: 3 notes lifted out of the sanitized live one, keys and nesting untouched. Deliberately a FIRST page (`has_more: true`, a populated `cursor`) so an integration test can page over it. The three cover keys are one, two and three segments deep — the `<id>`, `spectrum/<id>` and `oss-sg/notes_pre_post/<id>` shapes the live board sends, with synthetic segment names and verbatim depth — and one row is `type: "normal"` against two `type: "video"`. |
| `rednote-note-detail.json` (captured 2026-09-13) | `POST webapi.rednote.com/api/sns/web/v1/feed` | The **canary's** rednote NOTE-DETAIL capture — one whole note, `images=9 items=9 noteType=normal`. The envelope is `data.items[0].note_card`, **not** `data.notes`, which is why the challenge recognizer takes the payload key as a parameter. Nine `image_list[]` entries, all 1242×1660, `live_photo: false`, `stream: {}`, **no `video` key** — so K3b fans out one item per **image**, keyed `<note_id>:<position>`. The image keys are `oss-sg/spectrum/<id>`: **multi-segment**, the shape the old last-segment rule 404'd on. `title` and `desc` exist only here — a board row carries only `display_title` — and the author is `user.nickname` where the feed says `user.nick_name`. |
| `rednote-note-video.json` (captured 2026-09-14) | `POST webapi.rednote.com/api/sns/web/v1/feed` | The **canary's** rednote VIDEO capture — the one artifact 098 had never had, and the reason T6 was blocked. One `type: "video"` note: a **1-entry `image_list`** (the poster, already ingested by the cover pass as `<note_id>` — which is why `parseNoteDetail` refuses to fan a video note out) plus `video.media.stream`, an object of **four arrays** keyed `EF4`/`EF5`/`EF6`/`EF7`. **Only `EF4` is populated**, so the fixture fixes the rung shape and says nothing about the ordering BETWEEN buckets — `rednote-video.js` says so where a reader will see it. The one rung is `stream_type: 258`, `format: "mp4"`, 720×960, `master_url` on `sns-v11` with one `backup_urls[]` entry on `sns-v27`: same path, different shard. Those urls are served **already unsigned** (`/stream/1/110/258/<id>_258.mp4`) and `master_url` was fetched live — **206, `video/mp4`**. `video.media_v2` is a JSON **string** duplicating the whole media object and is never parsed. |
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
those assertions — which is why it sat 41 days stale. Its `media_key`s are the one thing no
longer pinned as literals: they were **real** until 498 (see "the composed fixtures had
never been sanitized at all"), and the tests now read them off the fixture.

`x-bookmarks-live.json` is a **straight live capture**, sanitized and otherwise
untouched, and it is what the canary runs (`FIXTURE.x`). It answers the only question
the canary asks — *does a response X sent today still parse* — and can be replaced
wholesale with a newer capture without touching a single test. `checkTimeline` still runs
over the composed fixture in `drift.test.js`, so both stay covered.

### rednote: the CDN host, the signing-prefix SHAPE and the `!` suffix are load-bearing
`toRednoteOriginal` returns its input **unchanged** unless the host ends in
`rednotecdn.com`, and it builds the unsigned original by dropping the **first two** path
segments of `/<timestamp>/<signature>/<key>` and stripping the `!transform` suffix. The
first pass of the sanitizer normalised the host to `sample2.example.com` and dropped the
suffix, which did not merely blur a signal — it switched the whole rewrite off, so a
fixture built from it would have proved the **opposite** of what the canary asks. The
sweep now keeps rednote's CDN hosts (`PLATFORM_HOST`, alongside `i.pinimg.com` and the
twimg split), keeps the `!…` directive beside the file extension, and still replaces every
segment.

Path **depth** used to be enough; it no longer is. The rewrite fires on the *shape* of the
first two segments — 10–14 digits then a 32-char hex digest — because rednote's video
streams are served **already unsigned** with real path in that position
(`/stream/1/110/258/<id>_258.mp4`), and a depth test rehosts them into a 404. So
`syntheticUrl` replaces a signing prefix with same-shaped filler
(`/000000000000/00000…0/`) rather than the `00/00` it gives every other segment, and
`bulk-rednote.test.js` asserts the SHAPE on the INPUT — signed host, a real
`<timestamp>/<signature>` prefix, a surviving `!` — so neither a re-capture nor a
sanitizer change can quietly go vacuous.

The note-detail fixture needed **no further sanitizer change** beyond that — the host, the
five-segment path depth and the `!` suffix all survived the sweep as it already stood,
and `audit-capture.js` printed `LEAKED: 0` first time. `bulk-rednote.test.js` asserts
the same input properties over every `image_list[].url_pre` / `url_default` /
`info_list[].url`, and additionally that the rewritten key is still **multi-segment** —
on the detail endpoint a flat key would mean the drop-two rule had quietly become the
last-segment rule again, which is the bug 098 T0 shipped to fix.

Two other things the rednote capture taught the sweep, both fixed there rather than here:
**display names are collected under `nick_?name`** (the feed spells it `nick_name`, note
detail `nickname` — and `Neurobin`, `LEE`, `ruirui`, `snow` are shape-identical to schema
constants, so shape alone could never reach them), and **counts are not always numbers**
(rednote ships `interact_info` counts pre-formatted as strings: `"27.7K"`, `"5,123"`).

### rednote again: the UNSIGNED half of the same CDN
The trap has now caught three fixtures in a row — 483 the CDN host, 485 the `!transform`
suffix, 487 the `<timestamp>/<signature>` shape — and the video capture walked into the
same one from the other side. rednote serves **video and subtitles with no signing prefix
at all**, and with real route where a prefix would sit: `/stream/1/110/258/<id>_258.mp4`,
where `stream` is the service, `1` the biz version, `110` the `biz_name` and `258` the
`stream_type`. Sanitized to `/00/00/00/00/SAMPLE.mp4` the fixture still parsed and the
canary still went green — while proving nothing at all about the two properties the video
ladder rests on: that the chosen url is an unsigned path `toRednoteOriginal` leaves alone
(487), and that the filename's `_<n>` suffix agrees with the rung's `stream_type` (020's
undecodable manual pick was a `_330`; this one is a `_258`).

So `syntheticUrl` gained a second branch beside the signing-prefix one: on a rednote CDN
path with **no** signing prefix, a segment that is a bare lowercase word or a number under
six digits is ROUTE and is kept verbatim — it cannot carry identity by construction, being
the same two classes the value sweep already treats as schema — and the filename keeps its
`_<stream_type>`. Everything else in those positions is still replaced. The one visible
side effect on the existing fixtures is that avatar urls now read
`/avatar/SAMPLE1` instead of `/00/SAMPLE1`; `rednote-board-live.json` and
`rednote-note-detail.json` were re-sanitized so that re-running the sweep still reproduces
them byte for byte, and re-sanitizing the Instagram and Pinterest raws reproduces **their**
committed files unchanged. `audit-capture.js` also learned that `mp4` is a container
literal: it is a bare word with a digit in it, so the lowercase rule could not reach it and
every rung's `format` reported as a leak. Enumerated, not loosened — `^[a-z][a-z0-9]*$`
would re-excuse `testing2` and `mariosworld343`.

**`video.media_v2` is deliberately destroyed.** It is a JSON *string* duplicating the whole
media object, and the sweep treats it as the long free text it looks like, so in the fixture
it is `"Sample text N"`. That is not damage — it is what makes "read the structured form,
never `media_v2`" **enforceable**: a parser that reached for it would produce nothing at all
against this fixture. `size` is likewise synthetic (it clears the numeric-id floor), which
is a happy accident worth keeping: a selector that sorted on it would be sorting on noise,
and sorting on size is exactly what 020 rule 1 forbids.

### rednote a third time: the transform that rides in the QUERY
The trap has now caught **five** shapes — 483 the CDN host, 485 the `!transform` suffix,
487 the `<timestamp>/<signature>` prefix, 488 the unsigned `/stream/` route, and 496 the
query. `syntheticUrl` rebuilt every url as `protocol//host/segments` and therefore dropped
the **whole query string**. That is correct for everything that normally rides in one —
`?sign=…` and `xsec_token` are credentials — and wrong for the one thing in a query that is
not identity at all: rednote's *other* transform spelling,
`?imageView2/2/w/540/format/jpg/q/75`, which is what a live `board/info` response puts on
every cover and what `toRednoteOriginal` now strips. Flattened away, such a fixture would
again prove the opposite of what the canary asks.

So a query component that is a **named transform directive** is kept verbatim and every
other component is still dropped. The predicate is `isTransformDirective`, **imported** from
`src/extractors/rednote.js` rather than respelled here — a private copy is precisely how the
fixture and the rewrite come to disagree, which is the whole content of 483/485/487/488.
Re-sanitizing every one of the 15 files in `resources/` produces **byte-for-byte** what the
pre-496 sweep produced: no capture there carries a query transform yet, so this is coverage
for the next `board/info` capture, not a rewrite of the current fixtures.

### The other direction: the composite id no rule was shaped for
Every note above is the sweep destroying something a fixture existed to prove. This one is
the sweep **keeping** something it exists to remove, and it had been there the whole time.

Instagram's media id is a composite — `<media_pk>_<user_pk>`, e.g.
`3936199039845197488_291775034` — and it rides four keys: `strong_id__` (132 distinct in
the 2026-09-14 page), `id` (132), `profile_pic_id` (35), `carousel_parent_id` (14). X ships
one too, the other way round: `media_key` is `<media_type>_<media_id>`, `13_2023807…`.
**Every rule missed it, and each for the same kind of reason.** `isLongDigits` was
`^\d{8,}[A-Za-z]?$` and the underscore breaks it. `isOpaqueId` and `isToken` both demand a
LETTER (`/[A-Za-z]/`) that a digits-and-underscore value does not have. So it fell through
the whole chain and rode out verbatim: **87 distinct real identifiers**, `LEAKED: 176`.

It was **masked, never handled**. The 2026-08-14 raw's composites all carry an 11-digit
user pk, so at 31 characters `isFreeText`'s `length > 30` swallowed every one of them
(18 distinct substrings; not one survived). The 2026-09-14 page also carries 7-to-10-digit
pks, and at 29–30 characters those walked straight through (379 distinct substrings, 87 of
them whole leaves). **No committed fixture was ever exposed** — the hole was real from the
first day and the data simply had not been shaped to reveal it yet. A rule that holds only
while a platform keeps issuing long enough user ids is not a rule.

The predicate is `isCompositeDigits`: **two or more all-digit runs joined by underscores,
where at least one run is long enough to be an id.** Three decisions, each from the data
rather than from the shape of the example:

- **Underscore only.** The other two separators that join bare digit runs in these captures
  are things this must not touch: `.` joins version numbers (`153.0.0`, `10.15.7`) and `,`
  joins rednote's display-formatted counts (`5,123`), which `COUNT_KEY` zeroes by key.
  Widening to `[^A-Za-z0-9]` would rewrite both — the same over-reach that once let
  `SCHEMA_CONSTANT` shield `testing2`, a pin description.
- **A run of six digits or more is an id and is replaced; anything shorter is kept.** Six,
  not eight: the shortest identity run anywhere in `resources/` is the 7-digit
  `profile_pic_id` owner in `3236034018967612385_8046568`, and the obvious floor to copy
  from `isLongDigits` would have leaked exactly that — the same way the all-digits first
  pass leaked `814154277899006v`. Six is also the boundary `isRouteToken` already draws.
- **The short run stays verbatim.** X's leading run is the photo/video discriminator (`3`,
  `13`, `7` — the only three values across every X raw here) and one or two digits cannot
  name anybody. Flattening it would cost the fixture the thing `media_key` is read for:
  `bulk-twitter.js` uses it as the per-ASSET `sourceId` and the canary fails the page if two
  collide. `bulk-twitter.test.js` asserts the SHAPE on the fixture for that reason.

Three more holes surfaced underneath it once the composites stopped drowning the report,
all the same failure — *a rule insisting on a character class the value happens to lack*:
X's base64 node id (`VXNlcjoyODQwNzIzMTg=` decodes to `User:284072318`, and base64 of a
short number contains no ASCII digit, which `isToken` demands); `MindfulMotif.com` and
`Deck.Gallery`, hosts that `isBareHost` could not see because it was anchored lowercase;
and `behance.net/creativemints`, a scheme-less `display_url` with no scheme for `isUrl`, a
slash `isBareHost` rejects, no leading slash for `isPath` and no digit for `isToken`.

### X's envelope and X's ids
`x-bookmarks-live.json` and `x-thread-detail.json` are the first X fixtures here produced
by the sweep rather than by hand, and that exposed two rules that had never been exercised
against a real X body.

**The envelope's type discriminators were being rewritten.** `entryType:
"TimelineTimelineItem"`, `__typename: "TweetWithVisibilityResults"`, `cursorType:
"ShowMore"` — `isOpaqueId` reads every one of those as an opaque handle (eight or more
characters, mixes upper and lower, matches no schema-constant rule) and turned them into
`SAMPLECODE1`. `bulk-twitter.js` compares them to string literals, so the sanitized page
parsed to **zero tweets and no cursor**. This one is drawn by KEY (`SCHEMA_KEY` in
`scripts/capture-keys.js`) and not by shape, because shape cannot do it: `TimelineTweet`,
`SelfThread` and `HighQuality` are the same PascalCase as `JayBorda`, `LeeScarfe` and
`RasmusNielsen`, which are people. A `__typename` is machine-generated by construction.

**And every numeric id was being stamped `+100000042`.** `isPhone` accepts a bare run of
seven or more digits and sat above `isLongDigits`, so it had been swallowing every id in
every capture — 898 distinct across `resources/`. Nothing leaked; the SHAPE did, and the
canary derives a tweet's identity from its permalink with `/status\/(\d+)/`, which
`https://x.com/sampleuser1/status/+100000002` does not match. There is not one real phone
number in any capture here: every punctuated `isPhone` hit in the corpus is this sweep's
own earlier output read back out of a `-clean` file. `isLongDigits` now runs first and
accepts a leading `-` (Pinterest board-feed ids can be negative).

**`screen_name` was not an identity key.** X's handle, 65 distinct real ones in the thread
capture plus 13 more under `in_reply_to_screen_name`, and not one was ever replaced —
`creativemints`, `framer`, `figma` and `awwwards` are bare lowercase words, so every value
rule reads them as enums and `audit-capture.js` was reporting them as **structural
survivors**. The August X fixtures did not leak them only because their handles were made
synthetic by hand. `location`, `short_name`, `subtitle`, `title` and `description` joined
the prose rule for the same reason: `Prague`, `Nantes`, `(dream)`, `Test-3` and `testing2`
are content that is character-for-character the shape of an enum.

### Pinterest's `/pin/<id>/`
`seo_url` was being flattened to `/sampleuser1/sample1/` along with every other
site-relative path, and six and a half weeks of Pinterest fixtures carried it without anyone
noticing, because every pin in them also has a canonical `id`. It is load-bearing twice
over: `pinIdFrom` recovers a pin's id from it with `/\/pin\/(\d+)/` when `id` is missing,
and `mapPinterestPin` composes the permalink from it directly. `syntheticPath` now keeps a
leading bare-lowercase-word segment **when a later segment is a bare long digit run**, and
replaces long digit segments with same-length synthetic ones. The condition is the whole
rule: `/sujenphea0843/websites/` has no id segment and keeps flattening whole, because
`websites` is a BOARD NAME and is character-for-character the shape of a route word.
`bulk-pinterest.test.js` asserts `/^\/pin\/\d+\/$/` on the fixture, so the next flattening
is a test failure rather than a silent one.

### The audit is a GATE now, not a report
`audit-capture.js` has always computed the one number that matters and has always exited
non-zero on it. Nothing ever ran it except a person deciding to, so `LEAKED: 176` sat in a
terminal unread. `sanitize-capture.js` now **audits its own output and refuses to write a
leaking fixture** — it imports `auditCapture` rather than respelling it, for the same reason
`isTransformDirective` is imported. A capture carrying a shape no rule knows about fails
loudly at the moment it is produced, which is the only moment anyone is looking.

Two key rules moved into `scripts/capture-keys.js` because the audit needs the same ones:
a survivor that arrived under an **identity** key is never excusable whatever its shape
(this is what makes a surviving `creativemints` a leak rather than a structural survivor),
and a value that appears **only** under a type-discriminator key is excused rather than
reported. Two private copies is precisely how a fixture and the check on it drift apart.
The structural list's short-number rule also tightened from `^\d{1,7}$` to `^\d{1,5}$` —
at seven it excused IG's 7-digit `pk` `8046568` and X's `9655742` outright.

### The composed fixtures had never been sanitized at all
They predate `sanitize-capture.js`. Checked against every raw in `resources/`,
`x-bookmarks.json` carried **40** real values (8 X media keys, base64 node ids, real tweet
ids and timestamps, a handle inside a `display_url`), `pinterest-boardfeed.json` **64** and
`pinterest-boards.json` **54** — including the account holder's **email address**, their
display name, their user agent and OS, their IP region and gender out of `client_context`,
and the `epik` / `unauth_id` / `push_package_user_id` tokens. All three were redacted
value-by-value through the sweep's own replacements, leaving every already-synthetic leaf
byte-for-byte alone, so the diff is only the redacted values. What remains of `resources/`
in them is API routes (`/resource/BoardsResource/get/`) and X schema constants
(`IconBriefcaseStroke`, `EnabledWithCount`). **Redacting the working tree does not remove
these from git history** — that is a separate decision and has not been taken here.

### Refreshing a live fixture
```
node scripts/sanitize-capture.js ../resources/<raw>.json ../resources/<clean>.json
node scripts/audit-capture.js    ../resources/<raw>.json ../resources/<clean>.json   # LEAKED: 0
```
`sanitize-capture.js` is the sweep described below, and it now runs the audit itself and
**writes nothing** if anything leaked, so the first command alone is the gate; the second is
for reading the report. Read the `structuralSurvivors` list every time rather than trusting
the count — a handle and an enum can be the same shape, so the split between "leaked" and
"structural" is a triage aid, not a verdict. Then overwrite the fixture and bump that
platform's `capturedAt` in `drift-baseline.json`.

**Expect assertions to break, and fix them by asserting the property.** Re-sanitizing
changes every synthetic id, so a test that pinned one fails. 498's five refreshes broke
eleven assertions across three files and every one was pinning an incidental value: a
hardcoded thread head and spine (now derived as the longest self-chain in the body, the way
`checkThread` does it), a literal tweet count (now compared against an independent recursive
scan of the same body), literal `media_key`s (now read off the fixture's own media list),
and a literal pin permalink (now composed from the pin's own `seo_url`, which is what made
redacting that pin id a test failure rather than a no-op).

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
- **Pinterest `X-APP-VERSION`** observed `cad034b` (2026-09-14), `be501f2` and `194583e`
  **four hours apart** (2026-08-14), `1df0da9` (2026-07-03) — it drifts **intraday**, not on
  a release cadence, which is why it is scraped at runtime from an inline
  `app_version":"…"` script and never sent from a constant. Note it is *not* the 403 trigger
  (see below); it is app-identifying only.
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

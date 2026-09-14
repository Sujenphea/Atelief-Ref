# 498 — the underscore no rule was shaped for

## Summary

`sanitize-capture.js` decides what to replace by **value shape**, deliberately. A fresh
Instagram capture sanitized with it left **87 distinct real identifiers verbatim** —
`audit-capture.js` reported `LEAKED: 176`. The surviving form is Instagram's composite id:

```
3936199039845197488_291775034      <media_pk>_<user_pk>
```

Every rule missed it, and each for the same kind of reason. `isLongDigits` was
`^\d{8,}[A-Za-z]?$` and the underscore breaks it. `isOpaqueId` and `isToken` both demand a
LETTER (`/[A-Za-z]/`) that a digits-and-underscore value does not have. It fell through the
whole chain. It rides four keys — `strong_id__` (132 distinct), `id` (132),
`profile_pic_id` (35), `carousel_parent_id` (14) — and X ships the same shape the other way
round, `media_key` as `<media_type>_<media_id>`, `13_2023807562760826880`.

**It was masked, never handled, and no committed fixture was ever exposed.** The
2026-08-14 raw's composites all carry an 11-digit user pk, so at 31 characters
`isFreeText`'s `length > 30` swallowed every one — **18** distinct in that file. The
2026-09-14 page also carries 7-to-10-digit pks, and at 29–30 characters those walked
straight through — **379** distinct. The hole was there from the first day; the data simply
had not been shaped to reveal it yet. A rule that holds only while a platform keeps issuing
long enough user ids is not a rule.

This is the sixth time in a week the sweep has been wrong, and the first in this direction.
483, 485, 487, 488 and 496 were all the same failure inverted — it **destroyed** the very
property a fixture existed to exercise (the CDN host, the `!transform` suffix, the
`<timestamp>/<signature>` prefix, the unsigned `/stream/` route, the `?imageView2` query).
Both directions have one root cause: **it guesses from shape, and nothing checked its
guesses against a capture it had not already seen.** So the audit is now a gate.

> **Index.** This entry is 498. The last written is 496; 489 and 497 were never allocated
> and are left unallocated, because indices are allocation-order and never reused.

## The predicate, and the evidence for each half

`isCompositeDigits` is **two or more all-digit runs joined by underscores, where at least
one run is long enough to be an id**. Three decisions, each derived from the corpus rather
than from the shape of the one example:

**Underscore only.** The other two separators that join bare digit runs in these captures
are things this must not touch: `.` joins version numbers (`153.0.0`, `10.15.7`, and
Pinterest's `story_pin_data.metadata.version` `0.16.0`) and `,` joins rednote's
display-formatted counts (`5,123`), which `COUNT_KEY` already zeroes by key. Widening to
`[^A-Za-z0-9]` would rewrite both — the same over-reach that once let `SCHEMA_CONSTANT`
shield `testing2`, a pin description.

**A run of six digits or more is an id and is replaced.** Six, not eight. The obvious floor
to copy is `isLongDigits`'s, and it is wrong: the shortest identity run anywhere in
`resources/` is the 7-digit `profile_pic_id` owner in `3236034018967612385_8046568`. An
`\d{8,}` floor leaks exactly that, the same way the all-digits first pass leaked
`814154277899006v`. Six is also the boundary `isRouteToken` already draws, and nothing
legitimate is caught by widening it: **every** five- and six-digit string in every capture
in `resources/` sits under a `*_count` key, which the sweep zeroes before any value rule
sees it.

**The short run stays verbatim.** X's leading run is the photo/video discriminator — `3`,
`13` and `7` are the only three values across every X raw here, and one or two digits
cannot name anybody. Flattening it would cost the fixture the thing `media_key` is read
for: `bulk-twitter.js` uses it as the per-ASSET `sourceId` and the canary fails the page if
two collide.

Run-length distribution across every raw in `resources/`, which is what settled the floor:

| shape | n | keys |
| --- | --- | --- |
| `<19>_<7…11>` | 109 + 93 + 4 + 2 + 1 | `strong_id__`, `id`, `profile_pic_id`, `carousel_parent_id` |
| `<1…2>_<19>` | 24 + 19 | `media_key` |
| *(nothing else joins bare digit runs with an underscore)* | 0 | — |

**Ordering is part of the rule.** The branch sits **above** `isFreeText`, because a
composite is only ever 21–31 characters and `length > 30` was catching the longest ones.
Below it, this rule would go on being shadowed for precisely the values that *did* get
sanitized and fire only for the ones that leaked.

## Three more holes were underneath it

Once the composites stopped drowning the report, three survivors were left, all the same
failure — *a rule insisting on a character class the value happens to lack*:

- **`VXNlcjoyODQwNzIzMTg=`**, X's GraphQL node `id`, which decodes to `User:284072318`.
  Base64 of a short number contains no ASCII digit, and `isToken` demands one; `=` is
  outside `isOpaqueId`'s alphabet. `isBase64Id` requires valid padded base64 that **decodes
  to printable ASCII** — decoding is the discriminator and it has to be, because
  `application/x-mpegURL` is also 21 url-safe characters with no digit, and it is a content
  type the X video mapper picks against. Simply dropping `isToken`'s digit rule was the
  obvious alternative and is wrong: it swallows `TimelineTimelineItem`,
  `XDTCarouselContainerMedia` and `VerticalConversation`.
- **`MindfulMotif.com`, `Deck.Gallery`, `JustInCase.co`** — hosts `isBareHost` could not see
  because it was anchored lowercase.
- **`behance.net/creativemints`, `pic.x.com/ThfGGeacLy`** — X's `display_url`, a
  scheme-less url with no scheme for `isUrl`, a slash `isBareHost` rejects, no leading slash
  for `isPath` and no digit for `isToken`. The host half is what keeps `isHostPath` off a
  mime type: `application` has no dot, so it is not a host.

## What a sanitizer-produced X fixture exposed

`x-bookmarks-live.json` and `x-thread-detail.json` are the first X fixtures here produced
by the sweep rather than by hand, and that exposed two rules that had never run against a
real X body. Both would have shipped a fixture that parses to nothing.

**The envelope's type discriminators were being rewritten.** `entryType:
"TimelineTimelineItem"`, `__typename: "TweetWithVisibilityResults"`, `cursorType:
"ShowMore"` — `isOpaqueId` reads each as an opaque handle and returned `SAMPLECODE1`.
`bulk-twitter.js` compares them to string literals, so the sanitized page parsed to **zero
tweets and no cursor**. This one is drawn by KEY, because shape cannot do it:
`TimelineTweet`, `SelfThread` and `HighQuality` are the same PascalCase as `JayBorda`,
`LeeScarfe` and `RasmusNielsen`, which are people, and a value rule wide enough to keep the
first three is an amnesty on the last three. A `__typename` is machine-generated by
construction. Across every capture in `resources/` those keys hold **30 distinct values and
every one is an envelope discriminator**.

**Every numeric id was being stamped `+100000042`.** `isPhone` accepts a bare run of seven
or more digits and sat above `isLongDigits`, so it had been swallowing every id in every
capture — **898 distinct** across `resources/`. Nothing leaked; the SHAPE did. The canary
derives a tweet's identity from its permalink with `/status\/(\d+)/`, which
`https://x.com/sampleuser1/status/+100000002` does not match, and the freshly sanitized
bookmarks page reported all seven of its tweets as mapping to no item. There is not one
real phone number in any capture here: every punctuated `isPhone` hit in the corpus is this
sweep's own earlier output read back out of a `-clean` file. `isLongDigits` now runs first
and accepts a leading `-`, because Pinterest board-feed ids can be negative.

**`screen_name` was not an identity key.** 65 distinct real X handles in the thread capture
plus 13 under `in_reply_to_screen_name`, never replaced — `creativemints`, `framer`,
`figma` and `awwwards` are bare lowercase words, so every value rule reads them as enums,
and the audit was reporting them as **structural survivors**. The August X fixtures did not
leak them only because their handles were made synthetic by hand. `top_likers` is the same
class one platform over (a bare array of handles with no identity-ish key on any leaf), and
`location`, `short_name`, `subtitle`, `title` and `description` joined a prose rule for the
same reason: `Prague`, `Nantes`, `(dream)` and `Test-3` are content that is
character-for-character the shape of an enum. That rule is **local**, not global-by-value
like the identity set — a profile whose location reads `Remote` must not go on to rewrite
every other `Remote` in the document.

**Pinterest's `seo_url` was being flattened** to `/sampleuser1/sample1/`, and six and a half
weeks of fixtures carried it without anyone noticing, because every pin in them also has a
canonical `id`. It is load-bearing twice: `pinIdFrom` recovers a pin's id from it with
`/\/pin\/(\d+)/` when `id` is missing, and `mapPinterestPin` composes the permalink from it
directly. `syntheticPath` now keeps a leading bare-lowercase-word segment **when a later
segment is a bare long digit run**. That condition is the whole rule:
`/sujenphea0843/websites/` has no id segment and keeps flattening whole, because `websites`
is a BOARD NAME and is character-for-character the shape of a route word.

## The audit is a gate now

`audit-capture.js` has always computed the one number that matters and has always exited
non-zero on it. Nothing ever **ran** it except a person deciding to, so `LEAKED: 176` sat in
a terminal unread through six sweeps. `sanitize-capture.js` now audits its own output and
**refuses to write a leaking fixture** — it imports `auditCapture` rather than respelling
it, for the same reason `isTransformDirective` is imported. A capture carrying a shape no
rule knows about fails loudly at the moment it is produced, which is the only moment anyone
is looking.

Two key rules moved into `scripts/capture-keys.js`, because the audit needs the same ones
and two private copies is precisely how a fixture and the check on it drift apart:

- a survivor that arrived under an **identity** key is never excusable whatever its shape,
  which is what makes a surviving `creativemints` a leak rather than a structural survivor;
- a value appearing **only** under a type-discriminator key is excused rather than reported,
  which is how the sweep can keep `TimelineTimelineItem` without the audit calling it one.

The structural list also tightened from `^\d{1,7}$` to `^\d{1,5}$` — at seven it excused
IG's 7-digit `pk` `8046568` and X's `9655742` outright — and gained a locale
(`en_US` on IG's `video_subtitles_locale`), an uppercase-tolerant mime type
(`application/x-mpegURL`), a dotted schema version and Pinterest's `board.{meal_plan}`
field mask, each with the evidence recorded beside it.

## Five fixtures refreshed, every audit clean

| fixture | raw | signals | survived | `LEAKED` |
| --- | --- | --- | --- | --- |
| `instagram-saved-live.json` | `02-ig-saved-page2.json` | posts=21 items=118 videos=38 | 32 | **0** |
| `x-bookmarks-live.json` | `02-x-bookmarks.json` | tweetCount=7 mappedTweets=7 mediaItems=12 | 25 | **0** |
| `x-thread-detail.json` | `02-x-thread.json` | tweets=28 withParent=27 chain=4 items=4 | 40 | **0** |
| `pinterest-boardfeed-live.json` | `02-pin-boards.json` | pins=25 pinEntries=25 mapped=25 | 47 | **0** |
| `pinterest-boards-live.json` | `02-pin-boards-list.json` | boards=4 | 47 | **0** |

Every survivor is response FORMAT: GraphQL typenames, snake_case and UPPER_SNAKE enums,
language codes, mime types, `dominant_color` hexes, Pinterest's `-end-` sentinel, the
platform hosts that survive by design, and short numeric substrings of zeroed counts. The
IG page went from 3 posts to all 21; the Pinterest board feed's 25 pins arrive as bare
`data[]` rows this time rather than 24 inside one story module, so `modules` went 1 → 0 and
`mapped` now equals `pins`. Both shapes are normal.

`drift-baseline.json` dates all four refreshed markers **2026-09-14** and records
Pinterest's `X-APP-VERSION` as `cad034b` — the fourth value seen, after two observed **four
hours apart** on 2026-08-14.

## The composed fixtures had never been sanitized at all

They predate `sanitize-capture.js`. Checked against every raw in `resources/`:

| fixture | real values | what they were |
| --- | --- | --- |
| `x-bookmarks.json` | **40** | 8 X media keys, base64 node ids, real tweet ids and timestamps, a handle inside a `display_url` |
| `pinterest-boardfeed.json` | **64** | the account holder's **email address**, display name, user agent, OS, IP region and gender out of `client_context`, the `epik` / `unauth_id` / `push_package_user_id` tokens, a real board id, another person's name and username |
| `pinterest-boards.json` | **54** | the same viewer subtree and the same email |

All three were redacted value-by-value through the sweep's own replacements, leaving every
already-synthetic leaf byte-for-byte alone, so the diff is only the redacted values. What
remains of `resources/` in them is API routes and X schema constants
(`IconBriefcaseStroke`, `EnabledWithCount`). **Redacting the working tree does not remove
these from git history** — that is a separate decision and is not taken here.

## Files changed

`extension/scripts/sanitize-capture.js` — `isCompositeDigits`, `syntheticCompositeId`,
`syntheticDigits`, `isBase64Id`/`syntheticBase64Id`, `isHostPath`/`syntheticHostPath`, a
case-insensitive `isBareHost`, a signed six-digit `isLongDigits` reordered above `isPhone`,
the route-aware `syntheticPath`, the `TEXT_KEY` prose rule, and the audit gate at the foot.
`extension/scripts/audit-capture.js` — `auditCapture` exported, leaves collected with their
keys, the identity and discriminator key rules, and four additions to `STRUCTURAL`.
`extension/scripts/capture-keys.js` — **new**: the two key rules both files read.
`extension/test/fixtures/` — the five live fixtures, the three composed ones,
`drift-baseline.json`, `README.md`.
`extension/test/twitter-thread.test.js`, `bulk-twitter.test.js`, `bulk-pinterest.test.js`.

No `src/` file changed. The extension's runtime behaviour is untouched by this entry.

## Verification

`npm test` — **962 total, 959 pass, 0 fail, 3 skipped** (961/958 before; the extra test is
the media-key shape assertion below). The 3 skips are 096's corpus and page-signal
fixtures, unrelated.

`node scripts/drift-check.js` — all nine arms pass **and it exits 0**, for the first time
since 2026-08-28. The staleness arm had been red on every run since, printing "No drift"
one line above a non-zero exit; all four dated markers are now 0d old.

### Assertions changed, and why

Re-sanitizing changes every synthetic id, so eleven assertions across three files broke.
Every one was pinning an incidental value:

- **`twitter-thread.test.js`** opened with a hardcoded thread head and a five-id spine
  copied out of a hand-written fixture. Six tests went red without a rule having changed,
  which is the tell. The chain is now **derived** as the longest self-chain in the body —
  what `checkThread` does when no focal tweet is named — and nothing in the file names an
  id, a handle, a tweet count or a chain length.
- **"finds every tweet, across both entry shapes"** asserted `=== 29`. It now compares the
  walk against an independent recursive scan of the same body for `tweet_results.result`,
  and additionally requires both entry shapes to be **present**, or the capture is not
  exercising the claim.
- **"each tweet stays a TWEET"** matched `/thread part 1/`. It now asserts each descriptor's
  text is the tweet's long-form `note_tweet` body where there is one and `legacy.full_text`
  otherwise — and that at least one tweet in the chain **has** a differing long-form body,
  so the precedence is exercised rather than restated. My first attempt asserted
  `legacy.full_text` outright and failed; the behaviour is right (a >280-char tweet's
  `full_text` is truncated) and the expectation was wrong.
- **"a swept tweet is recognised as worth expanding"** asserted `probeRoots` returns true
  for the head. It cannot on a sanitized body: `probeRoots` reads `legacy.reply_count` and
  the sweep zeroes every `*_count` by key, deliberately. The real behaviour is now pinned
  as `false` **with the count asserted zero beside it**, so the reason is in the file rather
  than a silent gap — and the rule itself is covered on synthetic bodies, where a
  `reply_count` can be set to 3 and to 0. A mutation confirms the pin is load-bearing.
- **`bulk-twitter.test.js`** pinned four `media_key` literals that were the account
  holder's REAL X media ids. They are read off the fixture's own media list now.
- **`bulk-pinterest.test.js`** pinned a real pin permalink and the account holder's display
  name. The permalink is composed from the pin's own `seo_url` (the host is still asserted
  as `www.` against an `nz.` input, which is the load-bearing half), and the author fields
  are read from `pin.pinner` behind a guard that the fixture still has them.

One test was **added**: `bulk-twitter.test.js` asserts every fixture media key still has
X's `<media_type>_<media_id>` shape. It is the one thing the tests around it cannot catch,
because they read the keys off the fixture and would happily compare two flattened values.

### Mutations

Nine against `src/`, run through the whole suite; each failed the tests that name it and no
others.

| mutation | fails |
| --- | --- |
| `selfThreadChain` returns the focal tweet alone | 19 — incl. 4 of the rewritten live tests |
| `collectConversationTweets` never descends into module items | 22 — incl. "across both entry shapes" |
| `stampGroup` restarts `carouselIndex` per group | 6 — incl. "maps to ONE post" |
| `tweetText` reads `legacy.full_text` first | 2 — incl. "each tweet stays a TWEET" |
| `collectMedia` stops keying on `media_key` | 14 — all four rewritten X assertions |
| `mapPinterestPin` keeps the regional host | 3 |
| `mapPinterestPin` ignores the pin's `seo_url` | **1 — only the rewritten assertion** |
| `mapTweet` describes every item, not the first | 1 |
| `needsThreadExpansion` always probes roots | 3 — incl. the pinned `false` |

Two against the fixtures, to prove the new shape assertions are not decorative: flattening
the composed pin's `seo_url` the way the old `syntheticPath` did fails 2 tests; flattening a
composed `media_key` to one opaque id fails exactly the new one.

Thirteen against the sanitizer, which `npm test` cannot reach (a fixture is data), so the
**gate** and the **canary** are what has to catch them:

| mutation | caught by |
| --- | --- |
| the composite rule removed entirely (the shipped defect) | GATE — `LEAKED` 173 / 24 / 10 |
| the composite rule below `isFreeText` | GATE — same three |
| the per-run floor at eight digits | GATE — `LEAKED: 1`, `8046568` |
| the prose-key rule removed | GATE — `(dream)`, `Test-3`, `test-3` |
| `isBareHost` anchored lowercase | GATE — `MindfulMotif.com` |
| the scheme-less `display_url` rule removed | GATE — 8 handles across two fixtures |
| the base64 node-id rule removed | GATE — `VXNlcjoyODQwNzIzMTg=` |
| `liker` dropped from the identity keys | GATE — `the__divyabansal` |
| the sweep stops collecting identities at all | GATE — 45 / 18 / 14 / 27 / 2 |
| `isPhone` restored above `isLongDigits` | CANARY — "7 of 7 tweet entries mapped to no item" |
| the type-discriminator shield removed | CANARY — "no tweet entries found", no cursor |
| `isLongDigits` floor back to eight | **survived — recorded, not chased** |
| the composite's short run replaced too | **survived — recorded, not chased** |

Both survivors are shape-only and neither can leak. An `isLongDigits` floor of eight sends
a 7-digit id to `isPhone` instead, which still replaces it — the six is about the id coming
back looking like an id, not about it coming back. And renumbering X's `13_`/`3_`
discriminator keeps it distinct per type and memoised per run, so nothing downstream can
observe the difference; it is kept verbatim for fidelity, and the new shape test pins that
it is still a `<short>_<long>` pair.

The `--rednote*` arms are the regression check for the rest: re-sanitizing all three rednote
raws with the new sweep and running the canary over the result reproduces
`notes=37 items=37`, `images=9 items=9`, and `streamType=258 bucket=EF4` exactly, with
`LEAKED: 0` on all three. Every mutation was reverted before committing.

## Migration notes

- **`sanitize-capture.js` can now exit non-zero and write nothing.** Any script or habit
  that assumed it always produces a file needs to check. The refusal prints the audit report
  and names the surviving values.
- **`audit-capture.js` exports `auditCapture(raw, cleanText)`** and only runs as a CLI when
  invoked directly. Its report is unchanged.
- **`extension/scripts/capture-keys.js` is new** and is imported by both. It holds no logic
  and reads no files, so importing it can never run a sweep.
- **Re-sanitizing an existing raw no longer reproduces its committed fixture byte for
  byte.** Composites, node ids, `screen_name`s, prose keys, hosts and route paths all change,
  and the id numbering shifts with them. That is the point of the entry, but it means the
  "re-running the sweep reproduces the fixture" check from 488 no longer holds across this
  commit for X, Instagram and Pinterest. It does still hold for the three rednote fixtures,
  which are unchanged.
- **The composed fixtures moved.** `x-bookmarks.json`, `pinterest-boardfeed.json` and
  `pinterest-boards.json` were described as deliberately frozen; they were redacted here and
  the three tests that pinned a redacted value were rewritten.

## Still unverified

- **The email address and tokens redacted out of the two Pinterest composed fixtures are
  still in git history.** Removing them is a history rewrite plus, for the session-ish
  values, rotation — neither is taken here, and both are the user's call.
- **A bare lowercase word that is a handle is still excused by the audit unless it arrives
  under an identity key.** `nabiistudio` and `lainyschulz` were reported as structural
  survivors until `liker` was added; the next such key will be invisible the same way until
  someone names it. Shape cannot close this and the value rules must not try — the
  `^[a-z]+$` class is also `pin`, `board`, `video`, `photo` and `clips`.
- **`x-thread-detail.json` can never exercise `probeRoots`**, because the sweep zeroes the
  count it reads. Replacing counts with a synthetic NON-zero number would fix that and is
  not done here: `carousel_media_count` is a `*_count` key, and `checkInstagramSaved`
  computes its expected fan-out as `media.carousel_media_count || carousel_media.length` —
  a non-zero synthetic would make the expected number wrong and fail the IG canary.
- **Whether the identity key list is complete for X.** `screen_name` was missing for the
  life of the file and was found by reading a report, not by a check. Nothing enumerates the
  keys a platform can put a name under.

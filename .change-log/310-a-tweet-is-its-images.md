# 310 — A tweet is its images

## Summary

A 4-image tweet used to save ONE image. `mapTweet` collapsed the media list to a
single `tweet`-kind asset: the first photo was fetched as its card image, and the
other three survived only as URL references inside `asset.payload` — listed in the
UI (`SharedThumbnail` drew a `🖼 4` count), linked in the detail view, and never
downloaded. Bookmark a 4-photo thread and three quarters of it wasn't actually
saved.

A tweet now **fans out to one item per media**, which is the shape
`bulk-instagram.js` has always had.

## The change is in the DRIVER, not the pipeline

Worth stating because it's why this is small: `ingestOne` downloads exactly one
media per relay, and the Instagram driver has always fanned out *before* the relay
(`mapSavedMedia` returns one `BulkItem` per `carousel_media[]` child). The pipeline
never needed to know. `mapTweet` simply wasn't doing it.

So it now returns `medias.map(...)` — one item per entry of
`extended_entities.media[]`, each with its own `mediaUrl`, all sharing the tweet's
`originalURL`. That shared permalink is `postGroupKey`'s input, so the app collapses
them to one tile with a `⧉ N` chip for free, and each child carries
`rawMetadata.carouselIndex` so 309 opens the tweet in ITS order rather than the
feed's. No app-side change was needed for any of that.

## What this costs

- **A tweet with media is no longer a card.** It has no `content` descriptor, so it
  ingests down the plain image path. The text and author are not lost —
  `makeProvenance` writes them to `title` / `authorHandle` / `authorName` on every
  child, which is where the provenance UI reads them — but it stops *rendering* as
  a tweet. A tweet with no usable media is still a single media-less `tweet` card;
  that is the case the kind exists for.

  This applies to SINGLE-image tweets too, which is the larger share of a
  bookmarks feed. The alternative — cards for 1 image, images for 2+ — makes a
  tweet's shape depend on how many photos it happens to have. If that is wanted
  anyway, the threshold is `medias.length > 1` on the branch in `mapTweet`.

- **The dedup key moved from the tweet to the media.** `sourceId` is the engine's
  skip key (`bulk-engine.js:279`), and one tweet now yields several items, so it
  has to be per-asset: `media_key`, falling back to `id_str`, then to
  `${tweetId}-${index}` so a response missing both still dedups WITHIN the tweet
  instead of collapsing every sibling onto one key (which would make the engine
  skip all but the first as already-seen).

  Consequence, accepted deliberately: previously-swept tweets look new on the next
  sweep. Blob-hash dedup means no duplicate bytes land — just a slower first pass
  and ledger entries for work that dedups. It self-corrects after one sweep.

- **4× the downloads** for a 4-image tweet. That is the point, but it is also the
  cost.

Two things got better on the way:

- **Video is per-child.** Each video/gif child stashes its OWN best progressive
  MP4, so a tweet with two videos resolves both under the opt-in; it used to keep
  only the first.
- **A media entry with no `media_url_https`** is dropped rather than emitted as an
  item the SW would fail to fetch, and `carouselIndex` is assigned over the EMITTED
  items so the grouping order has no hole in it.

## Files changed

- `extension/src/bulk-twitter.js` — `mapTweet` fans out; the module header rewritten
  (it documented the one-item-per-tweet contract in detail).
- `extension/src/drift.js` — `checkTimeline` counted media REFERENCES through
  `item.content.payload.tweet.media`, which no longer exists. It now counts items
  carrying a `mediaUrl` ("some", not "every" — a text-only tweet is legitimately
  media-less) and gained the duplicate-`sourceId` guard the IG check already had,
  which is only now meaningful for X.

## Verification

`npm test` in `extension/`: **397 pass, 0 fail.**

Thirteen tests pinned the old contract and were rewritten to the new one rather
than deleted — the fixture's 3-photo tweet now asserts three items, three distinct
media keys, indices 0/1/2, and ONE shared permalink (the grouping key). Two new
ones cover the fan-out's own edges: a media entry with no poster is dropped without
leaving a gap in the index, and media with neither `media_key` nor `id_str` still
gets per-sibling keys.

`parseTimelinePage` over the committed `x-bookmarks.json` now yields 5 items from 3
tweets, grouped 1 / 3 / 1 — four of those five used to be URL references nothing
ever fetched.

Not verified live: an actual sweep against a real bookmarks timeline. The fixture
is a sanitized snapshot, so this is pinned against the shape as of that capture,
not against X today.

# 390 — A tweet is still a tweet

Each tweet in a thread now acts like a separate tweet, and the thread still forms one
carousel. Those two sentences were in tension, and resolving it is the whole change.

## The tension

A thread's items were stamped with the HEAD's permalink so they would group into one
tile (`mapThread`, [090] 5A). But `PostGrouping.swift` derives the group key from
`source.originalURL` — so "group these together" and "this is which tweet" were the same
field, and only one of them could win.

Three attempts, each rejected for a concrete reason found before it was written:

1. **All items share the head's tweet id.** A tweet capture dedups on `(kind, tweetID)`,
   so eight items collapse to one asset and seven blobs are deleted as orphans
   (`IngestPipeline.swift:301-305`) while the ledger marks all eight done.
2. **Per-tweet tweet ids.** Each item's `originalURL` is rewritten to its own
   `canonicalTweetURL`, which shatters the carousel into five single-item posts plus a
   photo group.
3. **Decouple the two.** Grouping reads an explicit key when one is stated, and falls
   back to `originalURL` when it isn't.

(3) is what shipped, following the `carouselIndex` precedent already in the file.

## What changed

**`PostGrouping.swift`** — `postGroupKey(for:)` now resolves
`explicitPostGroupKey(for:) ?? source.originalURL` and runs the SAME normalization over
whichever it got, so a stated key behaves exactly as if it had arrived as the URL. The
new `explicitPostGroupKey(for:)` reads `rawMetadata["postGroupKey"]` — string-only,
non-blank — mirroring `carouselIndex(for:)` directly above it.

**`bulk-twitter.js`** — `stampGroup` writes `rawMetadata.postGroupKey` alongside the
permalink. One place, so `mapTweet` and `mapThread` both get it: `mapThread` needed no
change at all.

A tweet's FIRST item now carries a `tweet` content descriptor naming that tweet's own id,
text, author and full media list. Only the first, and keyed on that tweet's own id — for
the reason attempt (1) failed. One descriptor per tweet id is what keeps every image.

## Why there is no migration

It is an override with a fallback, not a new field to populate. No existing capture
carries `postGroupKey`, so every existing source takes the URL path unchanged — no
column, no backfill, and the ~50 existing grouping tests exercise the same code they
always did. That is what kept the change to ~55 lines across two repos.

## Files changed

- `AtelierRefs/AtelierRefs/PostGrouping.swift` — explicit key wins, same normalization
  (also: corrected a doc comment still claiming bulk-twitter emits one item per tweet,
  which the 310 fan-out ended)
- `AtelierRefs/AtelierRefsTests/PostGroupingTests.swift` — `ExplicitPostGroupKeyTests`
- `extension/src/bulk-twitter.js` — `stampGroup` stamps the key; `mapTweet` attaches the
  content descriptor to item 0
- `extension/test/bulk-twitter.test.js`, `extension/test/twitter-thread.test.js`

## Tests

Six Swift cases: the stated key wins, it normalizes identically to a URL, a missing one
falls back, a non-string is ignored, it works with no URL at all, and — the guard that
matters — two sources with DIFFERENT keys never fuse.

On the extension side, the live 29-tweet capture (`x-thread-detail.json`) yields five
descriptors with five distinct tweet ids, each carrying its own text, across eight items
under a single `postGroupKey`.

## Not done

`isRepresentative(_:)` has zero production callers.

**Corrected:** this entry first claimed the check was inlined in FOUR places
(`PostGrouping.swift:305`, `IngestionModel.swift:515`, `ShelfView.swift:354`, "the search
path"). That was wrong, and the conclusion drawn from it — that there was duplication to
unify — was wrong with it. What is actually there:

- **One** equivalent site, `PostGrouping.swift:352` in `collapsed()`, in the same file.
  It sits after the guard on line 346 that has already resolved `key` and `members`, so
  routing it through the helper would add two dictionary lookups per feed item to the
  path this file documents as the reason collapsing is cheap.
- `IngestionModel.itemsRepresented(by:)` is close but not a drop-in: it needs `lead`
  itself for the `expandedPosts` check, and it diverges on ungrouped items —
  `members(forItem:)` returns `[]` so its guard fails, where `isRepresentative` returns
  `true`.
- `ShelfView.swift` is a DIFFERENT predicate. It has no equality check at all; it widens
  any member to its whole post.
- There is no search-path site.

So the helper is unused and its three test assertions guard nothing that ships, but there
is no duplication to collapse and the one equivalent site inlines the check deliberately.
Left exactly as it is.

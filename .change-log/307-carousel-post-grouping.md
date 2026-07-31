# 307 — One tile per post: carousels collapse

## Summary

A multi-image post (an Instagram carousel, a multi-photo tweet) used to land in the
grid as N unrelated-looking tiles. Four near-identical images occupied four slots
that could have shown four different posts, and in a saved-posts feed — which is
mostly carousels — that is most of the grid.

Now a post is **one tile**. The `⧉ N` chip says how many images stand behind it, and
every action on that tile acts on all of them.

## The grouping key (the load-bearing decision)

Carousel members do **not** share a `source_id`. `AppServices.ingest` inserts a fresh
`Source` row on every non-dedup capture, so a four-image carousel is four assets with
four distinct source ids. What they share is the post permalink — the extension's
saved-feed parser hands every carousel child the post's own `originalURL`
(`bulk-instagram.js`: "Carousel children share the POST's permalink").

So the key is the normalized `Source.originalURL`. Three producers write that field
and they disagree, so the normalization has to reconcile them:

| Producer | Shape |
| --- | --- |
| `extractors/base.js` (`cleanURL`) | `origin + pathname` from the live page |
| `bulk-instagram.js` | synthesised `https://<host>/<p\|reel>/<code>/` |
| `AddLinkForm` → `LinkPayload.canonicalURL` | a hand-pasted share link |

`postGroupKey` therefore drops the query and `#fragment`, lowercases **scheme and
host only**, drops a leading `www.`/`m.`, and canonicalises `/reel/<code>` to
`/p/<code>` (both resolve to the same post — `bulk-instagram.js:176`). The **path
keeps its case**: an IG shortcode is case-sensitive, so lowercasing it would fuse
unrelated posts.

Direction matters here. Under-normalizing splits one carousel — visible and harmless.
Over-normalizing merges strangers into one post — invisible, and an action on one
post would reach another's images. The guard tests pin both directions.

## Why collapsing stayed cheap

Collapsing does **not** mean a cell holding several ids. `IngestionModel.items` is a
derived array, so the display list is simply a **shorter array of the same type**:
one item, one cell, one selectable id. Every index-based subsystem — the layout's
`aspects`, `nextGridIndex`, the marquee, reorder, `items[indexPath.item]` — is
untouched.

Fan-out happens at the **action boundary** instead. The selection holds only
representatives; `PostGroups.expand(_:)` widens to real members immediately before a
verb runs. That split is what keeps ⇧-range and marquee math working while "Delete"
still removes four things.

## Behaviour

- **Representative** — the post's first member in feed order; the tile stands at that
  position.
- **Actions** — delete, move, remove-from-collection and drag all widen to every
  member *in this feed*. The confirmation names items ("Delete 4 items") while the
  selection bar counts posts ("1 selected").
- **Half-filed post** — collapses to what is present; the chip shows that count.
- **Scope** — feed-scoped, never library-scoped. No new queries: this is a pass over
  data the grid had already loaded.
- **Toggle** — "Group carousels", persisted on `GridViewPreferences`, on by default.

## Files changed

**New**

- `AtelierRefs/AtelierRefs/PostGrouping.swift` — `postGroupKey(for:)`, the `PostGroups`
  index (`memberCount` / `members` / `isRepresentative` / `collapsed` / `expand`).
  Pure and view-free.
- `AtelierRefs/AtelierRefsTests/PostGroupingTests.swift` — key normalization (merges
  *and* non-merges), the index, collapse, expand, the badge pixmap, the `.union`
  reducer, the VoiceOver suffix. Includes `carouselSharesURLNotSourceID`, which fails
  loudly if anyone "fixes" the grouping onto `sourceId` and makes the feature inert.
- `AtelierRefs/AtelierRefsTests/PostGroupingWiringTests.swift` — the glue the pure
  tests can't see: the display list and reducer order stay in step, the toggle
  re-derives *and* bumps `itemsVersion`, and every action widens to the whole post.
- `AtelierRefs/AtelierRefsTests/MasonryGridItemBadgeTests.swift` — chip placement,
  the no-chip case, and reuse clearing it.

**Changed**

- `IngestionModel.swift` — sole owner of `PostGroups`; derives `displayItems` in the
  same pass; `groupCarousels` re-derives on change. `rebuildSelectedAssetIDs` and
  `actionTargets` widen through `expand(_:)`, which is what makes every verb fan out
  without each remembering to.
- `MasonryGridHost.swift` — reads `postGroups` from the configuration instead of
  rebuilding an identical index.
- `MasonryGridItem.swift` — `PostBadge` now draws from `Theme.NS` tokens rather than
  hardcoded white/black; `postMemberCount` is required (a defaulted `0` could silently
  drop the VoiceOver suffix).
- `GridContextMenu.swift` — `gridActionTargets` takes `cellAssetIDs: [UUID]`: the
  scope rule is unchanged, but one cell can now stand for several assets.
- `GridDensity.swift` — the persisted `groupCarousels` preference.
- `LibrarySearch.swift` — its own feed, but the same `collapsed`/`expand`, plus a
  `displayVersion` of its own (see below).
- `CollectionView.swift` — passes `displayItems` and mirrors the preference.

## The trap worth knowing about

`MasonryLayoutCache` is keyed on `(itemsVersion, width, columns, spacing, topInset)`.
Flipping the grouping toggle changes the display list while `items` is untouched, so
without a version bump the cache would serve the previous solve and lay the wrong
number of cells against stale analytic frames — and since hit-testing, marquee and
selection all ride those frames, clicks would land on the wrong tile. Both surfaces
bump: the model through `rebuildItemDerivations`, search through its own
`displayVersion` (it cannot use `resultsVersion`, which does not move when only the
toggle does).

## Removed

The sibling ring, `isPostSibling`, the host's `siblingCache` and its reconcile
symmetric-difference, both "Select N More from This Post" buttons, and the matching
context-menu item. With one tile per post there are no sibling tiles for any of it to
act on. `GridSelection.union` stays — it is the natural reducer for "select these
members" and is still tested.

## Verification

`AtelierRefsTests` passes in full under Swift 6 language mode: **1012 cases, 0
failures**, including 45 covering this feature.

Not yet eyeballed in the running app: chip legibility over dark artwork, and the
toggle's scroll/hit-testing behaviour after a flip (the layout-cache path is
test-pinned at the version level, but the visual result has not been watched).

## Still to do

There is no UI control for the toggle yet — the preference exists and is persisted,
but nothing surfaces it. It belongs beside the density controls. Expanding a
collapsed tile to see its members is also a follow-up; `DetailSession` already steps
through neighbours, which is the cheapest first version.

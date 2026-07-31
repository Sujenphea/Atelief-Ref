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
`aspects`, `nextGridIndex`, the marquee, `items[indexPath.item]` — is untouched.

The one exception is **reordering**, and it is worth naming because it was a real
bug: a drop slot is an index among the TILES the grid drew, so solving it against
`items` treats "after the 3rd tile" as "after the 3rd IMAGE". With carousels
collapsed that lands a drag near the start of the feed instead of where it was
dropped. `reorderItems` now solves in display space and widens back afterwards,
which also keeps a post's images contiguous after a move.

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
- **Opening a post** — clicking the `⧉ N` chip splices that post's members into the
  grid at their feed positions; clicking again re-collapses. It deliberately does not
  touch the selection: opening and picking are different intents, so a triage in
  progress survives a look inside. An OPEN post's members act **individually** —
  otherwise opening a carousel to delete one bad frame would delete all four, which
  is the thing you opened it to avoid.
- **Toggle** — "Group carousels" in Settings ▸ Grid, persisted on
  `GridViewPreferences`, on by default.

## Appearance

A collapsed post draws as a **pile**: two tilted cards behind artwork pulled in to
make room, reusing `fanRotations` — the same seeded tilt the Home overview cards use
— so a stack reads as a stack everywhere, and a given post's tilt is stable across
scrolls rather than re-rolled per render. An opened post keeps its chip (that is what
closes it) but loses the pile, since nothing is hidden behind it.

The chip is a **white capsule with dark contents**, the same inversion the selection
checkmark uses. The earlier translucent-dark chip vanished into dark artwork.

Two geometry facts the pile cost a bug each to learn:

- A rect rotated about its centre needs `w·cosθ + h·sinθ` of horizontal room, so the
  overflow scales with the OTHER dimension — one fixed inset cannot serve a masonry
  grid, and the cell clips. `fanPileGeometry` derives the inset from the angle and
  the cell size, capping the tilt first so a very tall tile trades angle for inset
  rather than shrinking its artwork. It also allows for the cell's CORNER RADIUS: a
  card fitted to the straight edges still gets its corners shaved by the arc.
- Assigning `frame` to a layer that already carries a rotation makes Core Animation
  back-solve `bounds` so the ROTATED box matches — the card shrinks a little more on
  every relayout. The cards set `bounds` and `position` instead.

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
- `SettingsView.swift` — a Grid section carrying the toggle. `AtelierRefsApp.swift`
  hoists `GridViewPreferences` to app scope and `ContentView.swift` receives it:
  Settings (⌘,) is a separate scene, so a `@StateObject` owned by `ContentView` would
  have given the toggle its own instance and the grid would never have seen it change.
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

`AtelierRefsTests` passes in full under Swift 6 language mode: **1030 cases, 0
failures**, including 60-odd covering this feature.

The geometry invariants are pinned rather than eyeballed: `pileNeverClips` rotates all
four card corners and checks them against the cell's ROUNDED rect across five aspect
ratios (square, tall portrait, the 200×900 a screenshot produces, a wide banner, a
dense-zoom notch). A bounding-box check passed while the pile was still visibly
clipped, which is why it checks corners now.

`PostReorderTests` pins the display-space drop: dragging the first of three collapsed
posts past the last tile lands it LAST, with its images contiguous and in order.

Not yet eyeballed in the running app: chip legibility over dark artwork, and the
toggle's scroll/hit-testing behaviour after a flip (the layout-cache path is
test-pinned at the version level, but the visual result has not been watched).

## Still to do

Nothing about the collapse itself is outstanding, but two things remain unverified by
anything other than tests: how the pile and the white chip actually LOOK over real
artwork, and scroll/hit-testing immediately after a toggle flip. Both need a library
with real carousels in it.

`FanCard` (the Home overview card) is still SwiftUI while the grid's pile is layers.
They share `fanRotations`, so the tilt cannot drift, but the card tone, border and
geometry are specified twice. Worth unifying for consistency — not for speed, since
Home draws a few dozen cards and is nowhere near the measured hot path.

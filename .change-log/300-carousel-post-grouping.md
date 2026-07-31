# 300 — Carousel grouping: badge, sibling ring, "select the rest of this post"

## Summary

A multi-image post (an Instagram carousel, a multi-photo tweet) lands in the grid
as N unrelated-looking tiles. Nothing said they belonged together, and nothing
let you act on them as a unit. This adds three connected affordances:

1. **Carousel chip** — a tile whose post contributes more than one item to the
   current feed draws a small `⧉ N` capsule in its top-leading corner.
2. **Sibling ring** — selecting one member draws a dashed accent ring on the
   post's remaining, unselected members, so you can see exactly which tiles they
   are without hunting for the badge count.
3. **"Select N More from This Post"** — a row in the collection selection bar's
   `…` overflow popover, a glyph button in the search selection bar, and an item
   at the top of the grid's right-click menu on both surfaces. Additive: it
   unions the siblings into the selection, so a triage in progress survives.

## The grouping key (the load-bearing decision)

Carousel members do **not** share a `source_id`. `AppServices.ingest` inserts a
fresh `Source` row on every non-dedup capture, so a four-image carousel is four
assets with four distinct source ids. What they share is the post permalink — the
extension's saved-feed parser hands every carousel child the post's own
`originalURL` (`bulk-instagram.js`: "Carousel children share the POST's
permalink"), and the same holds for Twitter and Pinterest.

So the group key is the **normalized `Source.originalURL`**: trailing slashes and
a `#fragment` stripped, case **preserved** (IG shortcodes are case-sensitive, so
lowercasing would merge unrelated posts). A source with no URL — a paste, a
dragged file — has no key at all, so local captures never collapse into one giant
group.

Grouping is scoped to the **loaded feed**, not the library: a carousel half-filed
elsewhere reports the two members actually on screen, because that is what the
badge promises and what "select the others" can actually select.

## Files changed

**New**

- `AtelierRefs/AtelierRefs/PostGrouping.swift` — `postGroupKey(for:)`, the
  `PostGroups` index (`memberCount` / `members` / `siblings` / `groupCount`), and
  `selectSamePostTitle(siblingCount:postCount:)`. Pure, view-free.
- `AtelierRefs/AtelierRefsTests/PostGroupingTests.swift` — key normalization, the
  index, the `.union` reducer action, the VoiceOver suffix. Includes
  `carouselSharesURLNotSourceID`, which fails loudly if anyone "fixes" the
  grouping onto `sourceId` and makes the whole feature silently inert.
- `AtelierRefs/AtelierRefsTests/MasonryGridItemBadgeTests.swift` — pins that the
  cell's backing layer shares the view's flipped geometry and that the chip
  therefore lands top-leading (clear of the top-trailing selection circle), plus
  the no-chip and reuse-clears-chip cases.

**Changed**

- `GridSelection.swift` — new `.union(Set<UUID>)` action: additive, collapses the
  live ⇧-range like any non-⇧ membership edit, moves the cursor/anchor to the
  last added item in feed order and returns `.scrollTo` so the grid follows.
- `MasonryGridItem.swift` — `PostBadge` (chip artwork, rendered once per distinct
  count and cached as an `NSImage`), a `CAShapeLayer` dashed sibling ring, an
  `isPostSibling` field on `CellSelectionState`, a `postMemberCount:` parameter on
  `configure`, and a carousel suffix on `gridCellAccessibilityLabel` (the chip is
  a pixmap VoiceOver can't read). Both are layer-only, matching the cell's
  no-SwiftUI-per-cell rule.
- `MasonryGridHost.swift` — builds `PostGroups` in `applyItems`, feeds the chip
  count in `configure`, and folds the sibling-set symmetric difference into
  `reconcileSelection`'s repaint targets (a cell can change ring without its own
  membership changing). The sibling set is memoized per selection so a scroll
  isn't O(cells × selected). Adds the context-menu item to both menu styles.
- `IngestionModel.swift` — `postGroups` rebuilt in `rebuildItemDerivations`, plus
  `samePostSiblings`, `selectSamePostRowTitle`, and `selectSamePost()`.
- `CollectionView.swift` — the popover row, pinned above the Move to / Add to
  sections and hidden (not disabled) when there is nothing to add.
- `LibrarySearch.swift` — its own `PostGroups` (search owns its own feed),
  rebuilt on `resultsVersion`, and a glyph button in the selection bar. Search's
  bar has no `…` overflow, so the count lives in the button's help text.

## Notes

- No schema change, no migration, no new reads: `CollectionItemDetail` already
  carries `source`, so grouping is a pass over data the grid had loaded anyway.
- The chip is a translucent-dark capsule rather than accent-coloured on purpose —
  it is permanently on every carousel tile and would otherwise compete with the
  accent selection ring right beside it. The sibling ring is dashed and thinner
  (2pt vs 3pt) than the selection ring for the same reason.

## Verification

`AtelierRefsTests` passes in full (including the 25 new cases). The rendered
appearance was **not** eyeballed in the running app — screen recording is not
permitted for this shell, so no screenshot could be taken. The one placement fact
that couldn't be established by reading the code (whether the flipped view's
backing layer flips its sublayer geometry, i.e. whether the chip lands top-left
or bottom-left) is asserted directly in `MasonryGridItemBadgeTests`; colour,
weight, and spacing are still worth a human look.

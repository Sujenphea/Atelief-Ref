# 309 — An opened post opens in ONE place

## Summary

Clicking a carousel's `⧉ N` chip (307) spliced the post's members back in at their
own feed positions. Nothing keeps a carousel's images adjacent in the feed — a
manual reorder, a partial move, or a re-file interleaves them with everything else
— so opening a post sprayed N tiles across the grid and the gesture read as
"some unrelated tiles appeared somewhere" rather than "here is what was behind
that tile".

An opened post now shows as a **contiguous run at the tile's slot**, in member
order, and only the run's **lead** carries the chip.

## The change

`PostGroups.collapsed(_:expanding:)` was a `filter` — which is exactly why the
members kept their scattered positions, since a filter cannot move anything. It is
now a walk that emits an ungrouped item where it stands, emits a post's lead where
it stands, and — when that post is open — emits the rest of its members
immediately after, in feed order. Non-representative members are never emitted in
place: they are either hidden behind the tile or already emitted beside their lead.

Both surfaces go through that one function (`IngestionModel`'s feed and
`LibrarySearch`'s), so neither needed touching.

The member lookup dictionary is built only when something is actually open. The
common case is an empty `expanding` set on every derivation, and that case now
costs the same walk it always did.

## This is a DISPLAY order, not a stored one

Opening a post persists nothing. `collapsed` produces `displayItems`, a derived
in-memory array; `manual_order` is written by `reorderItems` → `setGridOrder` and
by nothing else. Closing the post restores the grid exactly, and the behaviour
works in `.newest` / `.mostViewed` too, where the order is computed by the query
and there is no position to write in the first place.

What this does change is that `displayItems` is **no longer a subsequence of
`items`**. That is safe because nothing resolves a tile through its index in
`items`: the layout's `aspects`, the selection store's `order`, the marquee and the
reorder solve are all index-based over the DISPLAY list. Action widening
(`widenedForAction`, `assetIDs(for:)`) is id-based and walks `items` for feed
order, which is unaffected.

One consequence is worth naming because it is easy to mistake for a bug: a drag in
a `.manual` folder already rewrote every carousel into a contiguous run, open or
not. `reorderItems` solves in display space and widens with `itemsRepresented(by:)`,
so a collapsed tile contributes all its members back-to-back and the whole result
is persisted — that is 307's "keeps a post's images contiguous after a move", and
it applies to posts the user did not drag. Deliberately kept: with grouping on a
tile *is* a post, so moving tiles means moving posts, and it converges the stored
order toward what the grid shows.

## …and in the POST's order

Contiguous is not the same as correct: feed order is not the carousel's order, so
a shuffled post still opened 3-1-4-2. The real sequence was already on disk and
nothing had ever read it — `bulk-instagram.js:157` stamps
`rawMetadata.carouselIndex` on every child as it walks `carousel_media[]`, and
`raw_metadata` is a persisted TEXT column that round-trips losslessly.

`carouselIndex(for:)` recovers it, and `PostGroups.init` sorts each group by it.
Coverage is better than "one producer" suggests: `bulk-twitter` and
`bulk-pinterest` emit ONE item per tweet/pin (a multi-image tweet becomes a single
`tweet`-kind asset carrying its images as URL references in `asset.payload`, so it
never forms a post group at all), and the live-page extractors capture one image
per capture. A multi-asset group is a bulk-Instagram carousel in all but the odd
hand-captured case.

Two guards:

- **All-or-nothing.** A group is sorted only when EVERY member carries an index. A
  half-indexed post (a bulk carousel plus one image of the same post grabbed live)
  would otherwise interleave two provenance stories into one sequence with no way
  to tell which half is trustworthy. Feed order is at least an order the user can
  see and change.
- **Keyed on `(index, feed position)`.** `sorted(by:)` is not guaranteed stable,
  and two members sharing an index (a duplicate capture) must not be free to swap
  between derivations — the representative, and with it the tile's identity and
  slot, would flicker.

Sorting changes `members.first`, so the REPRESENTATIVE becomes the carousel's
image #1: the collapsed tile shows the post's own cover instead of whichever image
happened to land earliest, and it stands at that image's feed slot. For a
freshly-captured feed nothing moves at all — feed order and carousel order agree
until something reorders them. Only a shuffled post shifts, and it shifts to where
its cover is.

## One chip per open post

While a post is open, the chip is drawn on the LEAD only. Scattered members each
needed their own (any of them might be the one you could see); a contiguous run of
N tiles carrying N identical badges is just noise over what reads as a single
block. The lead's chip sits where the collapsed tile stood, so the thing that
opened the post is the thing that closes it.

`postMemberCount` is deliberately NOT zeroed for the other members — it also feeds
the VoiceOver "one of N from the same post" suffix, which every member of the run
needs whether or not it draws a badge. The cell takes an `isPostLead` flag instead
and gates chip painting on `count > 1 && (!expanded || isLead)`. `badgeHit` already
returns false when no chip is drawn, so the non-lead members simply route their
mouse-down normally.

## Files changed

- `PostGrouping.swift` — `collapsed(_:expanding:)` gathers an open post's members
  at the lead's slot instead of filtering in place.
- `MasonryGridItem.swift` — `isPostLead`, the `showsPostChip` rule, and the reuse
  reset for it.
- `MasonryGridHost.swift` — resolves the post's lead once and passes both facts.
- `IngestionModel.swift` — the `displayItems` doc now states the ordering contract
  and that nothing here is persisted.

## Verification

`AtelierRefsTests` passes in full (`** TEST SUCCEEDED **`).

New:

- `expandedPostIsContiguous` — the regression itself, over a feed where the post's
  three images are deliberately interleaved with two other posts.
- `expandingOnePostLeavesOthersCollapsed` — a neighbouring post stays one tile.
- `expandingANonLeadIsInert` — a stale or hand-rolled non-lead id must not
  half-open a post (the lead's tile plus a stray member).
- `openedMembersDropTheChip` / `collapsedAlwaysChips` — the chip rule in both
  directions; `openedPostDropsTheFan` now names the lead.

Not eyeballed in the running app: how the run reads against real artwork, and
whether the reflow on open wants an animation (it is an instant relayout today).

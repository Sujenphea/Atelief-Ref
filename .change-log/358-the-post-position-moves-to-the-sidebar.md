# 358 — The post's position moves off the top bar

## Summary

[356](./356-the-page-says-which-post.md) put the item's place in its post beside the
pager, as `⧉ 2 of 4 in this post`. On the built page it reads as clutter around the
prev/next chevrons — the one part of the top bar that is a *control*, now flanked by
a label that is not.

The fact stays; the chrome goes. It is now a **"Post" row in the sidebar's Source
section**, reading `Image 2 of 4`.

## Why Source, and not a section of its own

Post grouping is derived from the source — `postGroupKey(for: detail.source)` — so an
item that has a post always has a Source section to put the row in, and the row can
never be orphaned. It is also the same *kind* of fact as the rows already there:
Platform, Author, Title, Post. A section of its own would have been a heading for one
line.

## What this deletes

The chip sat in a `ZStack` whose centred child is proposed the bar's full width, so
`ViewThatFits` alone could never tell whether the chip collided with the trailing star
and overflow menu. 356 solved that with a measurement and a reserve. All of it goes:

- `topBarWidth` `@State` and the `.onGeometryChange` that fed it
- `topBarCentre`, `centreCluster`, `centredBudget`
- `sideClusterReserve = 104` — a constant tuned by reasoning about the Back pill's
  width, never measured on screen
- `postChip(_:short:)`, and with it the `⧉ 2/4` short form, which existed only to
  survive a narrow bar

`topBar` is once again Back · pager · star · overflow, exactly as 041 drew it.

`PostChipStyle` keeps the tokens the cell's pre-rendered chip uses and loses its three
SwiftUI-typed twins (`capsule`, `contents`, `weight`), which had no consumer left.
Unused constants raise no warning, so leaving them would have implied a second
renderer that no longer exists.

## Naming

`showsPostChip(memberCount:)` → **`showsPostPosition(memberCount:)`**. The rule did
not change — `> 1`, the same rule the cell states — but it is now named for the fact
rather than for the chrome, so the next move of this information does not date it
again. The cell's own `MasonryGridItem.showsPostChip` is untouched: that one really
does draw a chip.

## The division of labour, now settled

| says | drawn by |
|---|---|
| "this item belongs to a post" | the pile behind the artwork ([357](./357-the-pile-follows-the-picture.md)) |
| "you are on image 2 of 4" | the sidebar's Post row |
| "you are at 12 of 60 in the feed" | the pager |

080 §5.4 predicted two counters in one place would read as noise. They did. Separating
them by surface — one on the artwork, one in the panel, one in the bar — is what that
note was asking for.

## Files changed

- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — chip and its measuring apparatus
  removed; `post` threaded to `DetailSidebar` → `SourceSection`; the "Post" row;
  `showsPostChip` → `showsPostPosition`.
- `AtelierRefs/AtelierRefs/MasonryGridItem.swift` — `PostChipStyle`'s three orphaned
  SwiftUI tokens deleted; the "white capsule" rationale re-attached to the AppKit
  tokens that kept it true.
- `AtelierRefs/AtelierRefsTests/DetailPostTests.swift` — renamed to match; the T2
  agreement test and T4 mutation tests are unchanged in substance, since neither ever
  depended on where the number was drawn.

## Migration notes

None. `ItemDetailPost` is unchanged, so both grid-backed hosts and the Space board
call `ItemDetailView` exactly as before.

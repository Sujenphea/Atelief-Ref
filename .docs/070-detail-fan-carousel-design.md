# 070 — The detail page says "this is a carousel"

> An exploration, not yet a commitment. Once [069](./069-detail-arrows-plan.md) makes
> prev/next walk the post, the page still gives no sign that a post is what you are
> walking. Bring the grid's fanned pile onto the detail page so the carousel is obvious
> from the artwork itself.

## 1. The gap

[307](../.change-log/307-carousel-post-grouping.md) gave the *grid* a whole vocabulary
for "these came from one post": a `⧉ N` chip, a fanned pile of backing cards behind the
inset artwork, a chip-click that opens the post in place. The detail page inherited none
of it. `ItemDetailView` is fed an `asset`, a `source`, tags and a navigator
(`ItemDetailView.swift:66-117`) and has no idea a post exists.

So after 069 the page behaves correctly and still communicates nothing: → walks image
1→2→3→4 of a post and then out into the next tile, and at no point does the page say
which of those steps were "inside" the post. The counter reads `12 / 60` throughout. The
user clicked a pile and the pile vanished.

## 2. What to reuse

Both halves of the grid's treatment are already pure, tested and view-agnostic:

- `fanRotations(seed:count:maxDegrees:)` (`FanCard.swift:19`) — deterministic per-layer
  tilts from a UUID, so a post's fan is the same angle every launch, and the same angle
  the tile drew.
- `fanPileGeometry(in:maxDegrees:maxInset:minInset:cornerRadius:)`
  (`MasonryGridItem.swift:127`) — the inset a rotated card needs so no corner clips, at
  any aspect ratio.
- `PostBadge` (`MasonryGridItem.swift:154`) — the `⧉ N` chip, pre-rendered and cached by
  count.

Reusing `fanRotations` **seeded by the post's representative id** is the load-bearing
detail: the pile on the page is then geometrically the same pile the user just clicked in
the grid, which is what makes the transition read as "the pile opened" rather than as a
new decoration.

## 3. The proposal

### 3.1 Resting state — the artwork sits on its pile

Behind the fitted artwork, two tilted backing cards, inset by `fanPileGeometry`. Exactly
the collapsed tile's construction, at page scale. An ungrouped item draws nothing, so the
page is unchanged for the overwhelming majority of items.

### 3.2 The top bar says where you are inside the post

The pager already sits centre-stage (`ItemDetailView.swift:245`). Beside it, a chip in
`PostBadge`'s language:

```
‹  12 / 60  ›        ⧉ 2 of 4 in this post
```

Two counters, deliberately: the pager is the feed position, the chip is the post
position. That is also the honest answer to 069's counter question — the run counts
images, and the chip supplies the scope the run can't express.

### 3.3 The fan opens

Hovering (or clicking) the pile spreads it: the post's members fan out as a shallow arc
of thumbnails with the current one raised, and clicking one jumps straight to it. Since
069's run keeps a post contiguous, ← / → already walks the fan — the spread just makes
the walk visible and gives it a random-access shortcut.

Motion off `Theme.Motion.gentle`, matching the page's zoom transitions.

### 3.4 What the view needs

`ItemDetailView` is presentation-only by contract (`:10-15`), so the post arrives as data:

```swift
/// The post this item belongs to (307/309): its members in post order, the open
/// item's place in them, and a jump. `nil` for an ungrouped item, or a host with
/// no grouping context (the Space board).
struct ItemDetailPost {
    let index: Int              // 0-based, within the post
    let thumbnails: [URL?]      // members in post order
    let seed: UUID              // the representative id — the tile's own fan tilt
    let jump: (Int) -> Void
}
```

Both grid-backed hosts already hold everything: `postGroups.members(forItem:)`
(`PostGrouping.swift:194`), `model.thumbnailURL(for:)`, and — after 069 —
`detailRunIndex(of:)` to turn a member id into a step. `AsyncThumbnail` +
`thumbnailPixelBucket` are the same loaders `FanCard` uses, so the pile costs a handful of
cached thumbnails, bounded by the post's size.

## 4. Alternatives considered

- **A filmstrip rail under the artwork.** The most legible option and the most
  conventional — but it speaks a different visual language from the grid, permanently
  eats vertical room from the artwork, and for the common 2–4 image post it is a lot of
  chrome to say "there are three of these".
- **Chip only, no pile.** One line of work, and it does technically state the fact. It
  fails the actual brief: a chip in the corner is not *obvious*, which is the whole point
  of asking for the fan.
- **Fan only on hover.** Keeps the artwork pristine, but "obvious" and "hidden until you
  hover" are in direct tension. Better as the *spread* trigger (3.3) than as the pile's.

## 5. Risks, in the order they will bite

1. **The pile must track the ARTWORK, not the media area.** A fitted image rarely fills
   its pane, so a pile laid out against the pane's bounds floats detached on the long
   axis. This is precisely the bug [313](../.change-log/313-a-carousel-outlined-in-black.md)
   fixed in the cell (chrome laid out against `view.bounds` instead of the inset
   `contentRect`) — the page will need the fitted artwork's rect reported out of
   `ZoomableImage` the way the media area already reports its size through
   `onGeometryChange` (`ItemDetailView.swift:174`). Expect this to be most of the work.
2. **Zoom.** The pile is a fit-state affordance; at `zoom > 1` it must not draw, on the
   same gate the drag-out already uses (`zoom == 1`, `:466-467`).
3. **Non-image kinds.** Since [310](../.change-log/310-a-tweet-is-its-images.md) a tweet
   fans out into one asset per image, so a post's members can be a mix. Start with the
   image branch; decide video/tweet after seeing it.
4. **Two counters could read as noise.** Worth building 3.1 + 3.2 first and living with
   it before adding the spread — if the pile alone makes it obvious, 3.3 may be
   unnecessary.

## 6. Suggested order

1. `ItemDetailPost` plumbed through both grid-backed hosts, chip only (3.2) — cheap, and
   it proves the data path.
2. The artwork rect out of `ZoomableImage`, then the resting pile (3.1) — the risky half.
3. The spread (3.3), only if 1–2 leave it wanting.

Not scheduled: 069 ships first, and this should be judged against a page whose arrows
already work.

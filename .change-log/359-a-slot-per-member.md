# 359 — A slot per member

## Summary

`ItemDetailPost.blobHashes` was `[String]` with media-less members compacted out, and
its own doc called the misalignment deliberate. It was a trap, caught in review before
anything consumed it: it is now `[String?]`, one slot per member, `nil` where a member
has no artwork.

## The bug that had not happened yet

`jump` takes a **post-relative index** — the position of a member inside its post. The
spread ([080](../.docs/080-detail-fan-carousel-plan.md) §3.5) draws one card per entry
of `blobHashes` and jumps with the position of the card that was clicked. Those two
numbers agree only while every member has a blob.

Since [310](./310-a-tweet-is-its-images.md) a tweet fans out into one asset per image,
so a post's members can be a mix of kinds, and a media-less member (003 · O1) has no
blob. One such member anywhere in a post shifted every card after it by one:

| post | member | old `blobHashes` | card index | `jump` would open |
|---|---|---|---|---|
| 0 | image `aaa` | `"aaa"` | 0 | member 0 ✓ |
| 1 | *media-less* | — | — | — |
| 2 | image `ccc` | `"ccc"` | 1 | **member 1** ✗ |

Silent, and worst on exactly the posts 310 created.

## The fix

`ids.map { blobHashByItem[$0] }` rather than `compactMap`. `blobHashes[i]` is now
member `i` by construction, so "the i-th card is member i" is an invariant the compiler
carries rather than a coincidence the caller has to remember. A `nil` slot draws a
placeholder card, not a gap — the member is real, it is counted, the arrows walk onto
it, and it can be jumped to.

## Tests

`DetailPostMutationTests` previously pinned the *old* behaviour and asserted the
compaction was intended (`blobHashes == ["aaa", "ccc"]`). Those tests were rewritten to
state the new invariant rather than bent to pass:

- `mediaLessMemberKeepsItsSlot` — `["aaa", nil, "ccc"]`, plus the two facts the spread
  will rely on: `blobHashes.count == memberCount`, and `blobHashes[index]` is the open
  item's own slot. Checked from the media-less member *and* from a neighbour, so
  alignment cannot be accidentally keyed on who asks.
- `allMediaLessPost` — `[nil, nil, nil]`, not an empty list. An empty list would leave
  the spread with no cards for members that are undeniably there.

Full `AtelierRefsTests` target: **TEST SUCCEEDED**, 0 failures.

## Files changed

- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `blobHashes: [String?]`, and a doc
  that now records the trap instead of endorsing it.
- `AtelierRefs/AtelierRefs/PostGrouping.swift` — `map` for `compactMap` in
  `detailPost(forItem:thumbnailURL:jump:)`; `blobHashByItem`'s doc updated.
- `AtelierRefs/AtelierRefsTests/DetailPostTests.swift` — the two T4.4 tests rewritten.

## Migration notes

`blobHashes` has no consumer yet — the resting pile draws blank cards
([357](./357-the-pile-follows-the-picture.md)) and the position is text
([358](./358-the-post-position-moves-to-the-sidebar.md)). This lands ahead of the
spread so the spread can index it directly.

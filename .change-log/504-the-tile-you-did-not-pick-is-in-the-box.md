# 504 — the tile you did not pick is in the box

## Summary

P1 of [100](../.docs/100-spaces-group-frame-design.md): the model layer of ⌘G,
which wraps a multi-selection in an **ordinary frame**. No keystroke and no button
yet (P2), and no wash (P3) — just the geometry and the write.

There is almost nothing to the verb, and that is the design. A board already has
two ways to move tiles together; what it lacked was the one-keystroke way to *get*
a frame around a cluster you have already selected, instead of noting where it
sits, pressing `F`, and dragging a rect around it by eye. So ⌘G computes the rect
the user would have dragged and hands it to the existing `addFrame` path, which
already places the frame at the lowest z, selects it, and registers one undo step.
Nothing is created but the frame — no entity, no stored member set, no parent
pointer — which is why ⌘Z reverses it exactly: no tile was moved, restacked or
reparented, because membership is still derived from containment (062 §6).

The interesting part is what a bounding box does to bystanders. A box around the
selected tiles holds their centres by construction, and a stray unselected tile
sitting between them has its centre in there too — so the frame **adopts** it, and
a later drag will carry it. 100 §3 rejected shrinking the box to exclude it (for a
tile dead in the middle no such box exists, so the shortcut would sometimes
silently do something other than what it says) in favour of showing the user what
happened. That makes the adopted set a *result* of the gesture, not a side effect,
so `groupSelectionInFrame()` returns it for P3 to wash.

Which left one rule to be careful with. Adoption asks the same question frame
membership asks — *is this tile's centre inside this rect?* — and if the two ever
answered differently, the wash P3 draws would be a promise the next drag breaks.
`groupMembers(forTileID:in:)` was already the single place containment is decided,
so the predicate itself is lifted into a static `tileIDs(withCentreIn:among:excluding:)`
that both callers go through. 062 §6's "one rule, two callers" now has three.

Padding is `CanvasArrange.gridSpacing` (16) rather than a number of its own. A
frame flush against its contents reads as a bug (100 §4), and 16 is already the
board's one world-space breathing unit — the gap a bulk add flows tiles in at and
the gap every reflow leaves. A frame standing a different distance from its
contents than the contents stand from each other would put a second, unexplained
rhythm on the board. It is not decoration either: the padded band is part of the
frame, so a tile whose centre falls in the margin is adopted.

## Files changed

- `AtelierRefs/AtelierRefs/SpaceContent.swift` — the containment predicate lifted
  out of `groupMembers(forTileID:in:)` into a static
  `tileIDs(withCentreIn:among:excluding:)`; a pure static `groupBounds(for:in:)`
  returning the padded union of the selected tiles' world frames plus the adopted
  ids, `nil` below two tiles; `groupPadding`. Pure and `[Tile]`-only, so the rule
  is testable without a store or a database — `CanvasArrange`'s bargain.
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `groupSelectionInFrame()`, reading
  the LIVE tiles (a dragged tile's `items` row can still hold the pre-move x/y) and
  returning the adopted tile ids. `addElement` no longer derives the undo name from
  the kind: `addFrame(worldRect:actionName:)` threads one through, defaulted to
  "Add Frame" so every existing caller reads the same as before, and ⌘G passes
  "Group in Frame". Two gestures reach the same write, and the ⌘Z menu is the only
  place the user is told which one they did.
- `AtelierRefs/AtelierRefsTests/SpaceGroupFrameTests.swift` — two suites. The pure
  one pins the padding, adoption of a centre inside the union, NO adoption of a
  tile that overlaps the rect but is centred outside it, a selected frame
  contributing its own rect, and the below-two `nil`. The model one pins the
  created row (rect, kind, lowest z, selected alone, one undo step named "Group in
  Frame"), the no-op, and — the load-bearing one — that the frame actually created
  reports exactly `selection ∪ adopted` when asked what it contains.

## What P1 leaves standing

`groupSelectionInFrame()` is reachable from nothing: P2 adds the ⌘G binding and
button in `SpaceView` / `KeyMap`, P3 the timed wash the returned adopted set feeds.
Until then the adopted set is computed and discarded, and the gesture is silent
about bystanders — which is precisely the state 100 §3 argues is not good enough to
ship.

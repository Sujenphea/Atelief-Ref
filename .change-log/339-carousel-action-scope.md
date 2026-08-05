# 339 — A Tile Reading ⧉4 Means Four

[027] G1 and [022] D1: the keyboard's action scope is fixed, and the decoder the
two delete verbs will share lands ahead of the surfaces that will read it.

## The bug

Arrow onto a collapsed carousel tile reading ⧉4, press ⌫, and one image was
deleted — leaving the tile behind, now reading ⧉3. Right-clicking the same tile
and choosing Delete removed all four. The cause was one branch:

```swift
// IngestionModel.swift:2281 (before)
selection.isSelecting ? selectedAssetIDs : (leadItem.map { [$0.asset.id] } ?? [])
```

The lead branch took the asset id **raw**. Every other action path — the
selection cache (`rebuildSelectedAssetIDs`), the right-click scope
(`actionTargets(forCellItemID:)`), the drag payload — routes through
`widenedForAction(_:)` first, because a collapsed tile *stands for* its post. The
lead cursor was the one that did not, and `actionTargets` documents that exact
failure as the thing it exists to prevent.

`keyboardActionTargets` is read by `favoriteActionWouldStar`, `canToggleFavorite`
and `toggleFavoriteSelected` as well, so **⌘D on a lead carousel starred one image
of four**. That shared reader is why the fix is to the property rather than to
each verb: one line corrects both verbs at once, and any verb wired to it later
(`removeSelectedFromFolder`, still uncalled, is next) inherits the correction.

The lead now goes through the same two helpers as the right-click path —
`widenedForAction` then `assetIDs(for:)` — widening the **item** id, not the asset
id, since `widenedForAction` speaks membership ids. An **opened** post is
unchanged: its members still act one frame at a time, which is the deliberate
exception inside `widenedForAction` and the whole reason you open a post.

## The delete decoder (nothing consumes it yet)

`deleteIntent(characters:modifiers:) -> DeleteIntent?` — bare ⌫/⌦ → `.remove`,
⌘⌫/⌘⌦ → `.destroy`, ⌥ or ⌃ → `nil` (a word-delete inside a Name or Note field
must never be either), ⇧ and fn tolerated. fn *must* be tolerated: on a keyboard
with no Forward-Delete key, ⌦ **is** fn-⌫.

**No surface calls it.** [022]'s D2–D5 wire the grid, the space canvas, the detail
page and the Edit menu; landing the decision first means the behaviour change —
⌫ flipping from "delete from library" to "remove from this collection" — arrives
as one visible change instead of four staggered ones. It reuses
`gridIsDeleteKey(characters:)` so there is exactly one answer to "is this a delete
key", and it sits in its own file rather than beside `gridKeyCommand`: with four
consumers coming, "the pair means the same thing everywhere" has to be a property
of the code, not a convention four surfaces remember.

## Files changed

- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `keyboardActionTargets` routes
  the lead through `widenedForAction` + `assetIDs(for:)`; doc comment names the
  failure prevented, in the voice of the neighbouring `actionTargets` comment.
- `AtelierRefs/AtelierRefs/DeleteIntent.swift` (new) — `DeleteIntent` +
  `deleteIntent(characters:modifiers:)`. Pure, AppKit-flags only, unwired.
- `AtelierRefs/AtelierRefsTests/PostGroupingWiringTests.swift` — new
  `KeyboardActionScopeTests` suite (7 tests) on `CarouselRig`: collapsed lead → 4
  ids, opened post → 1, ungrouped → 1, `groupCarousels` off → 1, a non-empty
  selection still wins over the cursor, no cursor stages nothing, and ⌘D on a lead
  carousel stars all four. The property is `private`, so the suite drives it
  through `requestDeleteSelected()` / `toggleFavoriteSelected()` rather than
  widening access.
- `AtelierRefs/AtelierRefsTests/DeleteIntentTests.swift` (new) — the full
  bare/⌘/⌥/⌃/⇧/fn matrix over both ⌫ and ⌦, plus a contract test that the decoder
  claims exactly the keys `gridIsDeleteKey` claims.

## Migration notes

None.

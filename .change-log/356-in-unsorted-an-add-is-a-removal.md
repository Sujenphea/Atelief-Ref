# 356 — In Unsorted, An Add Is A Removal

[355] audited every way the item detail page goes down and fixed the three that
were wrong. It got one premise wrong, and the premise was load-bearing:

> `nil` for an add — an add cannot drop the item from anywhere.

An add can drop the item from exactly one collection, and it is the one the user
was standing in.

## The invariant that makes it a removal

Unsorted means *not filed*. `AppServices.addAssets` enforces it in the same
transaction as the insert:

```swift
if !intoUnsorted {
    try Self.evictFromUnsorted(db, assetIDs: assetIDs)
}
```

So from the Unsorted feed, adding the shown item to a collection files it — and
filing it unfiles it. The item leaves the run behind the page. `AssetTagsStore`
reported the add as `nil`, nothing armed, the reload found the shown id gone with
no intent, and `DetailStep.outcome` fell to its fourth guard: `.close`.

The chip machinery from [355] was working. It was told the truth about every
collection except this one.

The app already half-knew. `copyToCollection` picks its notice's verb with
`source == Collection.unsortedID ? "Moved" : "Added"` — the toast has always said
"Moved" here. Only the step disagreed.

## Where the eviction is named

**The funnel reports it.** `addAssets` returns the assets it evicted from
Unsorted, and `evictFromUnsorted` returns the ones that actually held a
membership (not the batch it was handed — most of a batch is usually filed
already). `@discardableResult`, so the forty-odd callers that don't care are
untouched.

The alternative was for `AssetTagsStore` to mirror the rule — one line,
`target == unsorted ? nil : unsorted`. That is a second copy of a funnel
invariant in a client, and this file already carries a comment about where that
leads: `applyAdd` measures its delta by reading the target's membership before
and after rather than predicting it, precisely because "reproducing both rules
here to guess the delta … is how an inverse silently starts removing a membership
the user had before." A rule stated twice is a rule that will disagree with
itself.

So the store passes through what the write says happened, and the collection an
edit took the asset OUT of is now the callback's whole meaning: the one a chip
removed it from, or Unsorted when the add evicted it there.

## The ⌥-drag had it too

Dragging the page's picture onto a sidebar collection with ⌥ routes to
`copyToCollection` → `addAssets` → the same eviction. Out of Unsorted the copy
empties its source, so [355]'s "⌥-drag is a copy and never leaves the feed" is
false in exactly this folder, and the page closed there too.

`copyToCollection` now arms through `armDetailStepIfShown(assetIDs:leaving:)`
with Unsorted as the collection being left — the same helper and the same two
guards the move path uses, so the shown item has to be in the batch and the
loaded run has to be the Unsorted one. The guard is the loaded folder rather than
the call's `source`, because a caller that passes no source (a Space board, a
search hit) has no Unsorted feed behind it to leave.

## The picker that offered nothing

[355] added an Add to / Move to segmented control to the detail bar's `+`
popover. In Unsorted the two sides compile to the same transaction — filing IS
moving there — so the host passes `onMoveToCollection: nil` when the loaded
collection is Unsorted and the popover is the plain destination list it was
before. Both halves step now, so the picker was harmless; it was also a
distinction the user would have had to unlearn.

## Corrections to [355]

Three statements in that entry are false in Unsorted, and are corrected here
rather than edited there — it shipped, and the exception is worth a record:

- "`nil` for an add — an add cannot drop the item from anywhere."
- "A chip ADDING another collection … reload[s] with the item still in the feed
  and the page stays put."
- "⌥-drag is a copy and never leaves the feed."

Each holds for every collection but Unsorted.

## Files changed

- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` — `addAssets`
  returns the assets it evicted from Unsorted (`@discardableResult`);
  `evictFromUnsorted` reads the doomed rows before deleting them and returns them.
- `AtelierRefs/AtelierRefs/AssetTagsStore.swift` — `addToCollection` reports
  Unsorted when the funnel says it evicted; `onMembershipChanged`'s argument is now
  "the collection the asset left", whatever the verb was called.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `copyToCollection` arms the step
  for an ⌥-drag out of Unsorted; `reloadAfterMembershipChange`'s contract updated.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — no Move verb in Unsorted.
- `AtelierCore/Tests/…/ServicesUnsortedInvariantTests.swift` — two tests: a mixed
  batch reports only the assets that actually held an Unsorted membership, and a
  repeat add reports nothing; an add INTO Unsorted reports nothing.
- `AtelierRefs/AtelierRefsTests/AssetTagsStoreCollectionsTests.swift` — a filing
  add names Unsorted, the additive add behind it names `nil`.
- `AtelierRefs/AtelierRefsTests/DetailStepTests.swift` — a `seededUnsorted` rig and
  three tests: an add out of Unsorted arms, an ⌥-drag copy out of Unsorted arms, a
  copy out of a real folder still arms nothing.

## Migration notes

**Behaviour change.** From the Unsorted feed, adding the shown item to a
collection — by chip or by ⌥-drag — steps the page to the next item instead of
closing it. Everywhere else, an add is still additive and the page still stays
put. The detail bar's `+` shows no Add/Move picker in Unsorted.

`AppServices.addAssets` returns `[UUID]` instead of `Void`. `@discardableResult`,
so every existing call site compiles unchanged. No schema, no settings.

[355]'s temporary `AppLog.model.debug` in `reloadAfterMembershipChange` is gone —
the behaviour it was there to explain is confirmed in a window.

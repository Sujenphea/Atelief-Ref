# 373 — The Collection Bar's Un-Widened Scope

Reported from use: multi-select in a collection, include a carousel tile, then
Archive / Delete / Move to / Add to — and **one image of the post moves, leaving
the tile behind reading one fewer**.

[371](371-archive-in-the-selection-bar.md) found and fixed this exact shape in
`ShelfView` and `LibrarySearch`, and in the same pass added the Archive glyph to
the collection bar. It did not look at what that bar's other four verbs were
already targeting.

## The root cause

`CollectionView` carried its own `selectedAssetIDs`:

```swift
private var selectedAssetIDs: [UUID] {
    model.items
        .filter { model.selection.ids.contains($0.item.id) }
        .map(\.asset.id)
}
```

`git log -S` dates it to 011/040 — it **predates carousel grouping** by a long
way. When 307 split what the selection HOLDS from what an action TOUCHES, every
other path was routed through the widening (`widenedForAction` → `assetIDs(for:)`)
and this property was not. It then shadowed `IngestionModel.selectedAssetIDs`,
which is the widened, feed-ordered, cached answer, at every call site in the file.

A collapsed post's selection holds only its representative, so the filter returned
exactly one asset per carousel tile no matter how many images stood behind it.

The bar's five verbs — Delete, Remove from collection, Archive, Move to, Add to —
were all wrong. The keyboard (`⌫` `⌘⌫` `E` `⌘D` `M` `A`, via `keyboardActionTargets`)
and the right-click menu (via `actionTargets(forCellItemID:)`) were right the whole
time, which is why this survived: the same verb through a different door did the
right thing, so the bug looked like a carousel problem rather than a bar problem.

**The fix is a deletion.** The property is gone and the call sites bind to
`model.selectedAssetIDs`. There is no second implementation of the scope rule left
in the view to drift.

## The readers that never leave membership-id space

Three more paths took `selection.ids` **raw**, for the same reason — they work in
`CollectionItem.id`, so they never touched the asset-id funnel that does the
widening:

- **⌘C** — copied one image of a ⧉4 tile.
- **Contact sheet / web page export** — exported one.
- **Quick Look** — previewed one, which is the least defensible of the three: the
  panel is where you go precisely to see what is behind the tile.

`IngestionModel.itemIDsForAction(_:)` now exposes the same rule in membership ids
and all three call it. Quick Look widens on **both** branches, so `Space` on a
collapsed tile with no selection flips through the whole post; `leadID` is the
tile, which is in the widened set, so the flip still starts where the cursor is.
An empty set widens to empty, which the two exports depend on — they read empty as
"no selection, take the whole collection".

## Set as Cover keeps reading the tile

The one verb here that is about the TILE rather than its post. `selectedAssetIDs`
is widened and ordered by the FEED, so its `.first` is the post's earliest member
in feed order — which drifts off carousel image #1 the moment a reorder or a
partial move separates the two orders. It now resolves the selected membership id
directly through the new `assetID(forItem:)`, so the cover set is the cover drawn.

## Tests

Seven, as `SelectionBarActionScopeTests`, including the reported case: a ⧉4 tile
selected alongside two lone captures yields 6 assets from 3 tiles, not 3.

The limit is worth stating plainly — the bar is a SwiftUI body and cannot be
driven from a unit test, so what these pin is the **seam**, not the view. They
would not have caught the original bug, because the seam was correct and the view
reached past it. What they do cover is genuinely new: `itemIDsForAction(_:)`,
`assetID(forItem:)`, and the parity assertion that the bar's list and the
keyboard's list are equal id for id and in the same order.

Full suite green.

## Files changed

- `CollectionView.swift` — the shadow deleted; 5 bar verbs, ⌘C, 2 exports, Quick
  Look and Set as Cover repointed
- `IngestionModel.swift` — `itemIDsForAction(_:)` and `assetID(forItem:)`
- `PostGroupingWiringTests.swift` — `SelectionBarActionScopeTests`

## Migration notes

None. No API or schema change; both new members are additive.

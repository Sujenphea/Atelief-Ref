# 316 — The detail page's arrows

## Summary

Prev/next on the item detail page misbehaved whenever the feed held a carousel. Two
defects, no shared mechanism, reported as one:

1. **← / → did nothing.** The image and the `N / total` counter never moved.
2. **The ‹ › chevrons moved — through the wrong list.** They stepped image-by-image into
   carousel members the grid was not showing as tiles, in raw feed order.

That the two controls disagreed is the tell: the chevron's action *is*
`navigator.step(±1)` and the shortcut was declared on that same `Button`, so one closure
served both. A divergence could only mean the key press never reached the button.

## Cause 1 — the grid ate the arrows

`MasonryNSCollectionView` takes first responder on the click that opens the page ("focus
follows the click", `gridCellMouseDown`) and keeps it: the page is an OVERLAY in the same
window, and nothing resigns for it. `gridKeyDown` then consumed ← / → unconditionally.

So every press *did* something — it walked the grid's hidden cursor and scrolled the grid
behind the overlay. `close()` overwrites that cursor on the way out, which is why the
evidence vanished and it read as a dead key rather than as a grid that wandered.

269 had already written the rule this violates: *"`keyDown` only reaches a first
responder … so the canvas's own focus is the gate."* A sibling `keyboardShortcut` is not a
gate. The page had no focus of its own, so it could not win.

## Cause 2 — two lists, one of them unseen

307 and 309 moved everything grid-facing onto `displayItems` — layout, the selection
store's order, the marquee, the reorder solve. The detail navigator was left on the raw
feed:

| | list | order |
|---|---|---|
| the grid draws | `model.displayItems` | one tile per post; an opened post's images contiguous, in post order |
| the pager walked | `model.items` | every image, raw feed order |

So the page stepped into hidden members in the order 309 had already stopped using, and —
once a reorder, a partial move or a re-file had interleaved a post — not even
contiguously: the arrows wandered into unrelated images and came back to the rest of the
post further along. The counter was over `items.count`, a total the grid never shows.

The seam was documented (`IngestionModel.displayTile(for:)`, "the detail overlay steps
through ALL items"), but only the *sync back on close* was ever fixed. Library search
carried both defects in the same shape.

## The fix

**One ordered run: the post as one run.** Tiles in grid order, with each post's images
opened out contiguously in post order — `A → post#1 → post#2 → post#3 → B`. Nothing is
unreachable from the page, and the order is the one the grid already draws.

It is `collapsed(_:expanding:)` with every post opened, so display order and page order
come out of one rule and cannot drift:

```swift
func fullRun(_ items: [CollectionItemDetail]) -> [CollectionItemDetail] {
    collapsed(items, expanding: Set(membersByKey.values.compactMap(\.first)))
}
```

`IngestionModel` derives `detailRun` + `detailRunIndexByItem` beside `displayItems` in
`rebuildItemDerivations()` — same pass, same invalidation. The index also retires a
`items.firstIndex { … }` scan the overlay ran on every body pass. Search derives the same
run through two file-scope producers (`searchItems(for:)`, `searchDetailRun(_:groupCarousels:)`),
because its page is presented one view above the grid that groups; two copies of that
mapping would have been two feeds that could disagree.

**A focus of its own.** `DetailKeyCatcher` is a keyboard-only `NSView` that borrows first
responder while the page is up, maps ← / → in `keyDown` off a pure
`detailStepDelta(characters:modifiers:)`, and hands the responder back when it leaves the
window. It arms ONCE per presentation and never steals from an `NSText`, so the sidebar's
Name / Note fields keep their caret keys. `hitTest` returns `nil`, so a full-bleed
background view stays out of mouse routing entirely. The chevrons' `.keyboardShortcut`s
are gone — a second registration could only step twice.

**And a gate on the grid.** `GridHostConfiguration.isDetailPresented` makes `gridKeyDown`
fall through while the page is up, so the grid can't move behind it even if the catcher
fails to arm. Two behaviours deliberately survive: Escape still closes (falling through is
what the Escape branch already did), and Delete still reaches `gridDeleteCommand()`,
because the delete key arrives via the `deleteBackward:`/`deleteForward:` responder
methods, which never came through `gridKeyDown`.

The collection surface reads the flag off `nav.presentedItemID`, not
`model.isDetailPresented`: that flag is deliberately un-`@Published` (036 §3 B4) and is
written from `CollectionDetailHost`'s `onChange`, so a body reading it could render before
it was set.

## Files changed

- `AtelierRefs/AtelierRefs/PostGrouping.swift` — `fullRun(_:)`
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `detailRun`, `detailRunIndex(of:)`
- `AtelierRefs/AtelierRefs/CollectionView.swift` — the navigator/session sites,
  `isDetailPresented` into the grid config
- `AtelierRefs/AtelierRefs/LibrarySearch.swift` — `searchItems(for:)`,
  `searchDetailRun(_:groupCarousels:)`, overlay ordering, `isDetailPresented`
- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `detailStepDelta`, `DetailKeyCatcher`,
  chevron shortcuts removed
- `AtelierRefs/AtelierRefs/MasonryGridHost.swift` — the config flag and the `gridKeyDown`
  gate
- `AtelierRefs/AtelierRefsTests/{PostGroupingTests,PostGroupingWiringTests,SelectionCellDeltaTests}.swift`

## Giving the keyboard back

Focus is claimed once, when the page opens, and deliberately not re-claimed on every
redraw — that would pull the caret out of the Name / Note field mid-word. But nothing
hands focus BACK when a field is done with it, so once you had typed in the sidebar the
arrows stayed caret keys for the rest of the page's life.

A click on the picture is the "done editing" signal. It bumps `keyFocusToken`, and the
catcher reclaims first responder — from a text field too, which is the one case
`armIfNeeded` refuses. `endEditing(for:)` runs first, so the field editor resigns through
AppKit's own path and `DetailField`'s focus-loss commit fires: clicking the artwork SAVES
the name being typed rather than dropping it.

The gesture is `simultaneousGesture(TapGesture())` and scoped to the media area, both
deliberately. Simultaneous so it never competes with zoom/pan, and a tap only fires on a
click that did not become a drag, so drag-out is untouched. Scoped, because the same
gesture over the sidebar would fire on mouse-UP and steal focus from the very field just
clicked into — making it impossible to type in.

Still open: clicking a top-bar chevron does not reclaim focus (an AppKit button never
takes first responder), so ← / → after a mid-edit chevron click still need one click on
the picture.

## Notes

Display-only, as 309 was: `manual_order` is untouched and nothing about the run is
persisted. No migration.

Design notes: `.docs/069-detail-arrows-plan.md`. The follow-up —
`.docs/070-detail-fan-carousel-design.md` — covers the other half of the complaint: the
page walks a post correctly now, but still never says a post is what you are walking.

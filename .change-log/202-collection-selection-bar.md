# 202 — Collection multi-select action bar

## Summary

`CollectionView` gains a floating bottom action bar for its grid multi-selection,
mirroring the bars Home (`CollectionsGalleryView`) and Search (`LibrarySearch`)
already have. The bar is an **additive** second path to the batch actions — the
grid's native right-click menu (`MasonryGridHost.buildContextMenu`) is left fully
intact, and every bar button calls the SAME `IngestionModel` method the menu does,
so the two paths can't diverge.

Decisions (confirmed with the user): keep the right-click menu and add the bar;
bar visible whenever ≥1 item is selected; Move to / Add to / Set as Cover collapse
into one `…` overflow menu while Remove + Delete are direct buttons; styling
mirrors Home's floating capsule. Plan: `.docs/042-collection-selection-bar-plan.md`.

## How it works

- Shown via `.overlay(alignment: .bottom)` on `content`, gated on
  `model.selection.isSelecting`. It's mounted on `content` (not `body`'s ZStack),
  so it sits BENEATH the full-window detail overlay and is hidden while a detail
  page is open.
- `selection.ids` are membership ids (`CollectionItem.id`); the model methods take
  asset ids, so a new `selectedAssetIDs` computed maps through the current feed —
  the same lookup `presentQuickLook` already does.
- Bar contents: `N selected` · Clear (`selectionStore.apply(.clear)`) · a `…`
  overflow · Remove · Delete. The `…`, Remove, and Delete are icon-only with
  hover tooltips (`.labelStyle(.iconOnly)` + `.help`).
- The `…` overflow is a **popover with `arrowEdge: .top`** so it opens ABOVE the
  bar (a plain `Menu` opens downward and clips off the floating capsule). It holds
  nested `Menu`s reproducing the old submenus — Move to → `moveToCollection`,
  Add to → `copyToCollection` — plus Set as Cover → `setCollectionCover` only when
  exactly one item is selected; each action dismisses the popover.
- Remove N → `removeFromFolder`; Delete N → `requestDelete` (runs its own
  confirmation — no new dialog).
- Destinations come from the existing memoized `moveTargets`; a small
  `destinationButtons` builder lists subfolders, a divider, then roots — the same
  order as the native `targetSubmenu`.

## Files changed

- `CollectionView.swift` — added `selectedAssetIDs`, `selectionBar`, and
  `destinationButtons`; mounted the bar as a bottom overlay on `content`. No other
  file changed — `MasonryGridHost`, `GridSelection`, `GridSelectionStore`, and
  `IngestionModel` are untouched (the bar reuses their existing seams).

## Notes / follow-ups

- Three near-identical selection bars now exist (Home, Search, Collection). Kept
  inline to match the current per-screen convention; extracting a shared
  `SelectionBar` component is a candidate future refactor.

## Verification

- `xcodebuild -scheme AtelierRefs build` → **BUILD SUCCEEDED**.
- The bar reuses already-covered model methods (`moveToCollection`,
  `copyToCollection`, `setCollectionCover`, `removeFromFolder`, `requestDelete`)
  and the `GridSelection` store; the new code is view wiring, build-verified.

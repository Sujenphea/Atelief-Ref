# 042 — Collection multi-select action bar (plan)

## Goal

Give the collection detail view (`CollectionView`) a floating bottom **action
bar** for its multi-selection, mirroring the bars Home (`CollectionsGalleryView`)
and Search (`LibrarySearch`) already have. The bar is an **additive** second path
to the batch actions that today live only in the grid's right-click menu.

## Decisions (confirmed with the user)

1. **Keep the right-click menu; add the bar alongside it.** The AppKit
   `NSMenu` (`MasonryGridHost.buildContextMenu`) is left untouched. The bar and the
   menu both call the same `IngestionModel` methods, so the two paths can never
   diverge in behavior.
2. **Bar is visible whenever `≥1` item is selected** (`model.selection.isSelecting`,
   i.e. `!ids.isEmpty` — there is no separate multi-select mode flag).
3. **Move to / Add to / Set as Cover collapse into one `…` overflow menu**;
   **Remove** and **Delete** are surfaced as direct buttons.
4. **Style mirrors Home's floating capsule** (`.regularMaterial`, `Capsule()`,
   shadow, bottom padding). **Set as Cover** appears in the overflow only when
   exactly one item is selected.

## How it works

### Current state (what exists)

- `CollectionView.swift` renders the grid through `MasonryGridHost` and already
  observes `model.selectionStore` (so a selection change repaints the screen).
- Batch actions live in the AppKit-native context menu built in
  `MasonryGridHost.buildContextMenu(forCellItemID:)` — **Move to ▸**, **Add to ▸**,
  **Set as Cover** (single only), **Remove from Collection (N)**, **Delete (N)** —
  wired via the `GridHostConfiguration` closures set in `CollectionView.appKitGrid`:
  `onMoveToCollection`, `onCopyToCollection`, `onSetCover`,
  `onRemoveFromCollection`, `onDelete`.
- Selection is `GridSelection` (`GridSelection.swift`) owned by
  `GridSelectionStore` (`GridSelectionStore.swift`). **`selection.ids` are
  membership ids (`CollectionItem.id`), NOT asset ids** — the closures above take
  asset ids, so the bar must map membership → asset the same way the detail
  overlay already does:
  `model.items.filter { selection.ids.contains($0.item.id) }.map(\.asset.id)`.
- `moveTargets` (this screen's memoized move/copy destinations) is already computed
  in `CollectionView`.

### Bar layout

```
[ N selected · Clear · [ … ▾ ] · Remove N · Delete N ]
```

- **N selected** — `Text("\(model.selection.ids.count) selected")`.
- **Clear** — `model.selectionStore.apply(.clear)`.
- **`…` overflow** — a SwiftUI `Menu` (nested `Menu`s reproduce the old submenus):
  - `Menu("Move to")` → `moveTargets` (subfolders, divider, roots) → `model.moveToCollection(assetIDs:to:)`
  - `Menu("Add to")` → same destinations → `model.copyToCollection(assetIDs:to:)`
  - only when `selectedAssetIDs.count == 1`: `Button("Set as Cover")` → `model.setCollectionCover(collectionID:assetID:)`
- **Remove N** — `model.removeFromFolder(assetIDs:)`.
- **Delete N** (`role: .destructive`) — `model.requestDelete(assetIDs:)`, which
  already runs its own confirmation, so no new dialog is added.

### Mounting

`.overlay(alignment: .bottom) { if model.selection.isSelecting { selectionBar } }`
on `content`, so the bar sits **beneath** the full-window detail overlay (hosted
later in the `body` ZStack) and is hidden while a detail page is open.

## Files changed

- `CollectionView.swift` — the only file that changes:
  1. `selectedAssetIDs: [UUID]` computed (membership → asset map).
  2. `selectionBar` view (Search's `selectionBar` pattern, extended with the `…`
     menu and a Remove button).
  3. `.overlay(alignment: .bottom)` mount on `content`.
  4. Reuse the existing `moveTargets` computed for the destination lists.
- **No change** to `MasonryGridHost.swift`, `GridSelection.swift`,
  `GridSelectionStore.swift`, or `IngestionModel.swift`.

## Notes / follow-ups

- Three near-identical `selectionBar`s now exist (Home, Search, Collection). Kept
  inline here to match current convention; extracting a shared `SelectionBar`
  component is a candidate future refactor, tracked separately.

## Verification (planned)

- `xcodebuild -scheme AtelierRefs build` → BUILD SUCCEEDED.
- Manual: 1 selected shows Set-as-Cover in the overflow; ≥2 hides it; Move / Add /
  Remove / Delete act on the whole selection; Clear and Esc dismiss; the right-click
  menu still works unchanged.

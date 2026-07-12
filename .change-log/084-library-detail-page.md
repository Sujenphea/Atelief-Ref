# 084 — Library detail page (replaces inspector)

## Summary

Removed the Library tab's trailing `.inspector()` panel. Clicking a grid cell now opens a
full-window **detail page** over the Library tab: the media fills most of the width — a
full-resolution image, or an inline AVKit `VideoPlayer` for video — with the item's
metadata / provenance / source actions docked on the right (ported from the old
inspector). ← / → step prev/next through the folder's items in place; Escape or a Back
button returns to the grid.

## Files changed

- **Added** `AtelierRefs/AtelierRefs/ItemDetailView.swift` — the detail page
  (`ItemDetailView` + private `DetailSidebar`). Reads `model.selectedItem`; loads the
  full-res blob off-main via `model.blobURL(for:)` (using `model.previewImage` as an
  instant placeholder) for images and builds an `AVPlayer(url:)` for video; prev/next via
  `.keyboardShortcut(.leftArrow/.rightArrow)` calling `model.select`; player is
  paused/released on item change and on close. Adds a **Duration** row for videos.
- **Edited** `AtelierRefs/AtelierRefs/LibraryView.swift` — dropped `showInspector`, the
  `.inspector(...)` modifier, and the "Toggle Inspector" toolbar item; wrapped the
  `NavigationSplitView` in a `ZStack` and overlay `ItemDetailView` when
  `showDetail && model.selectedItem != nil` (the guard auto-dismisses when the item is
  removed/deleted); grid cell tap now also sets `showDetail = true`.
- **Deleted** `AtelierRefs/AtelierRefs/InspectorView.swift` — its metadata/provenance/
  actions sections and helpers moved into `DetailSidebar`.
- **Added** `.docs/022-item-detail-design.md` — design spec.

## Migration notes

- No `IngestionModel` changes — all plumbing reused (`selectedItem`, `items`, `select`,
  `blobURL(for:)`, `previewImage`, and the existing action methods).
- The inspector and its toolbar toggle are gone; the Browser Capture toolbar item is
  unchanged. Error alerts live in `ContentView` (unrelated prior refactor).
- New dependency: `import AVKit` in `ItemDetailView.swift` (first use in the app target).
- Xcode uses file-system synchronized groups, so the added/deleted files need no
  `.pbxproj` edits.

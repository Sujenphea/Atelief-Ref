# 226 — Collection: whole-panel drag-select (marquee)

## Summary

The Collection grid's rubber-band selection now spans the **entire detail panel**,
not just the inset grid rectangle. Previously a drag could only start inside the
cell area — the 24pt margins, the strip above/below the content, and the header row
were all dead zones. Three changes close those gaps:

1. **Margins draggable.** The 24pt content margin moved out of a SwiftUI `.padding`
   around the grid and INTO the collection layout as `contentInsets`. The
   `NSCollectionView` now spans the panel edge-to-edge, so its background `mouseDown`
   (the marquee/click-to-clear seam) fires in the margins too. Column count and cell
   size are unchanged: the layout keys column math off the *content* width (panel −
   margins), and the density/zoom/skeleton call sites subtract the margin to match.

2. **Empty area below a short grid draggable.** `collectionViewContentSize.height` is
   floored to the viewport, so the document view fills the clip view even when there
   are few items — the marquee background now covers the blank space under the last
   row. The coordinator invalidates on a viewport *height* change so the floor tracks
   a vertical resize (width-only invalidation would leave it stale).

3. **Header band draggable.** `NSHostingView` reports its host view for *any* point
   with content (empty OR a control), so a press on the scroll-away header couldn't be
   told apart from a press on a button — a probe confirmed a `hitTest` override alone
   couldn't fall empty space through while keeping a button clickable. The header's
   **New Subfolder button was removed** (creation already lives in the sidebar
   collection tree's "New Subfolder…", 222), leaving the header purely non-interactive
   title + count. `MasonryHeaderContainer.hitTest` now returns `nil`, falling the whole
   band through to the marquee.

Net: margins, the top/bottom strips, the empty-below-content area, AND the header row
all start a marquee now. Search still keeps its own SwiftUI padding for now (the new
`contentInsets` defaults to zero, so search and every prior caller are unchanged).

## Files changed

- `MasonryLayout.swift` — `layout(…)` gains `leadingInset`/`trailingInset` (default 0):
  columns pack into `availableWidth − leading − trailing`, frames offset by `leading`.
- `MasonryLayoutCache.swift` — memo key + `frames(…)` thread the two insets through.
- `MasonryCollectionLayout.swift` — new `contentInsets`; `prepare()` folds top margin +
  header + grid inset into the item top inset, insets the header attrs, keys column
  count off content width; `collectionViewContentSize` adds the bottom margin and
  floors to the viewport; tracks `preparedViewportHeight`.
- `MasonryGridHost.swift` — `GridHostConfiguration.contentInsets`; coordinator applies
  it (with invalidate-on-change via `NSEdgeInsetsEqual`); `clipFrameChanged` invalidates
  on viewport height change too; `MasonryHeaderContainer.hitTest` → `nil`.
- `CollectionView.swift` — dropped the outer `.padding(Theme.Spacing.xl)`; passes
  `contentInsets`; skeleton re-applies the margin as plain padding; density/zoom/width
  capture subtract the margin; removed the header New Subfolder button and its orphaned
  state (`showNewSubfolder`/`newSubfolderName`/`newSubfolderParentID`) + alert.

## Migration notes

- **Behavioral:** the header's "New Subfolder" button is gone from the Collection
  screen. Use the sidebar collection tree's row context menu → "New Subfolder…"
  (`CollectionsOutlineView`), the always-available entry point (per 222).
- **Search/other grids:** unaffected — `contentInsets` defaults to zero and search
  retains its existing `.padding`. Applying the whole-panel marquee to Search and Home
  is deliberately out of scope for this change.
- No data or schema changes.

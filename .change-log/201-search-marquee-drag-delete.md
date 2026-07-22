# 201 — Search: marquee select, drag-out, delete action bar

## Summary

The search results grid (`LibrarySearchResults`) gains the same triage affordances
Home has: a marquee (drag-rectangle) selects result cells, a floating action bar
deletes the selection, and selected results can be dragged onto a sidebar
collection / space row to add them there. Search hits are membership-less, so a
drop onto a collection COPIES (adds) — it never moves items out of an unrelated
folder.

## Files changed

- `AssetDragPayload.swift` — extracted the sentinel `nilSourceID` (the all-zero
  "no source collection" id) as a named constant; `internalMarker` now uses it.
- `DropRouter.swift` — a drop onto a collection from a MEMBERSHIP-LESS drag (the
  sentinel source: search results / a Space board) resolves to `.copy`, with or
  without ⌥ — there is no source to move out of. Real-source drags are unchanged
  (move by default, copy with ⌥).
- `DropRouterTests.swift` — added `collectionSourcelessCopies` covering the rule.
- `LibrarySearch.swift` (`LibrarySearchResults`):
  - **Marquee** — result-cell frames captured via `onGeometryChange` in a shared
    `"searchResultsContent"` coordinate space; a background catcher runs a
    `DragGesture` and feeds `marqueeRect`/`marqueeIndices` into the existing
    `GridSelection` reducer (`.marquee(hits:base:)`). Empty-area click / Esc clears.
  - **Drag-out** — each cell is `.draggable(AssetDragPayload)` (whole selection if
    the cell is selected, else just itself; sentinel source ⇒ copy). The sidebar
    drop targets (`handleCollectionDrop` / `handleSpaceDrop`) already accept it
    unchanged.
  - **Action bar** — a bottom-anchored "N selected · Clear · Delete N" capsule,
    routing Delete through the existing staged/undoable asset delete
    (`model.requestDelete(assetIDs:)`), same as ⌫ and the context menu.

## Notes

- Reuses everything possible: the pure `MarqueeMath`, the `GridSelection` reducer
  (already used by search for click/⌘/⇧/⌘A), the asset delete + undo backend, and
  the sidebar's generic drop handlers. Only the SwiftUI gesture/overlay/drag wiring
  is new — the search grid is a plain `LazyVGrid`, not the AppKit `MasonryGridHost`.
- Semantics match the search context menu (which only offers "Add to Collection" =
  copy), extended to spaces (add) via drag.

## Verification

- `xcodebuild -scheme AtelierRefs build` → **BUILD SUCCEEDED**.
- KNOWN PRE-EXISTING BLOCKER: the `AtelierRefsTests` target does not compile
  (`NavModelTests` calls a removed `NavModel.openSpaces()`), so the new
  `DropRouterTests` case could not be run through it. The added rule is
  straightforward and asserted by that test.
- Drag-from-search onto a sidebar row is a native drag best confirmed by running
  the app.

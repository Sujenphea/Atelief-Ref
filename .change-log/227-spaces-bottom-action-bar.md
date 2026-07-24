# 227 · spaces — canvas controls moved to floating bottom action bar

## Summary

The Spaces canvas hosted its undo/redo, z-order, and add controls in the native
SwiftUI window `.toolbar`. They now live in a **floating bottom action bar** over
the canvas, reusing the shared selection-bar chrome so the pill matches the
Collection / Search selection bars.

- **New bar**: `SpaceView.actionBar` — a flat `HStack(spacing: 2)` of
  `SelectionBarButton` glyphs wrapped in `.selectionBarChrome()`, hung off the
  canvas via `.overlay(alignment: .bottom)`. Contents: Undo · Redo · Bring to
  Front · Send to Back.
- **Alignment**: no dividers between glyphs (parity with the other three bars,
  which use spacing only); a `.padding(.trailing, 10)` balances the chrome's
  text-tuned leading inset for this icon-only variant.
- **Behavior preserved**: keyboard shortcuts (⌘Z / ⌘⇧Z / ⌘⇧] / ⌘⇧[) ride the
  buttons; disabled glyphs dim to 0.35 opacity rather than vanishing so the row
  stays stable; z-order still gates on a selection, undo/redo on the space's
  `UndoManager`.
- **Add button removed**: assets enter a space by dragging them in from a
  collection, so the in-space "Add from Library" button, its `showAddSheet`
  state, and the `AddFromLibrarySheet` presentation were dropped. Empty-state
  hint and file header reworded to match.

## Files changed

- `AtelierRefs/AtelierRefs/SpaceView.swift` — removed the `.toolbar` groups and
  the add-sheet; added `actionBar` + `.overlay(alignment: .bottom)`; reworded the
  empty-state hint and header comment.

## Migration notes

- None. UI-only; no data, schema, or model changes.
- The library-add entry point is gone from the space view — adds now come solely
  from dragging assets in from a collection.

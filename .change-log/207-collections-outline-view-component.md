# 207 · NSOutlineView sidebar component (043 Phase C2 — built, not yet wired)

## Summary

The AppKit `NSOutlineView` component for the sidebar Collections tree — the live
drag-reorder/nest view (043 · decision 1C). It COMPILES and its drop logic is
covered by the C1 tests (`routeOutlineDrop`), but it is **not yet wired into
`SidebarView`**: the swap needs in-app verification (AppKit drag/drop, disclosure,
sizing, styling can't be unit-tested) and one parity gap must be closed first
(asset-drop onto rows). Landed as a reviewed checkpoint on the feature branch.

## What's in the component (`CollectionsOutlineView.swift`)

- `CollectionNode` — id-equality reference nodes so expansion survives reloads;
  `CollectionNode.tree(from:unsortedID:)` (Unsorted pinned, manual order).
- `CollectionsOutlineView: NSViewRepresentable` — non-scrolling (lives in the
  sidebar's SwiftUI `ScrollView`), reports content height back via a `@Binding`
  for the wrapper to size it. Native left-triangle disclosure + indentation.
- `CollectionsOutlineCoordinator` — data source + delegate:
  - Memoized tree rebuild (only when a folder snapshot changes) — 043 · 13A.
  - Selection synced both ways with `NavModel.sidebarSelection`.
  - Drag: writes `CollectionDragPayload`; Unsorted is not draggable. Drag-start
    caches the dragged folder's descendant set once per session — 043 · 14A.
  - Drop: `validateDrop`/`acceptDrop` delegate to the pure
    `CollectionTargets.routeOutlineDrop(...)`; applies via
    `IngestionModel.applyCollectionDrop`.
  - Native row context menu (`NSMenu`): New Subfolder… / Rename… (call back to
    SwiftUI alerts) · Move to ▸ (valid parents + Top Level) · Delete.

## Not done yet (the wiring step)

- **Swap** `SidebarView.collectionsSection` from the SwiftUI tree to this view.
- **Asset-drop parity**: the current SwiftUI rows accept ASSET drags (drag images
  from the grid onto a collection to move them — 009 · N3). The outline view only
  registers the folder-reparent type today; it must also register `.assetIDs` and
  route asset drops, or that feature regresses.
- **In-app verification** (`/run`): drag feel, disclosure, height/scroll sizing,
  and how the AppKit list's styling sits against the hand-tuned SwiftUI sidebar.

## Status

Build green; C1 drop-routing tests green. The SwiftUI sidebar tree remains the
LIVE UI — nothing user-facing changed. Wiring + verification is the next step.

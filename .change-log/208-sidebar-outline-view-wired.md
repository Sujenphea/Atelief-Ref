# 208 · Sidebar Collections tree → NSOutlineView (043 Phase C2 wired)

## Summary

Swaps the sidebar Collections tree from the SwiftUI VStack to the AppKit
`CollectionsOutlineView` (043 · decision 1C), giving native disclosure and live
drag — drop a folder ONTO a row to nest, BETWEEN rows to reorder (persisted
order), and drag grid assets onto a row to move/copy them (009 · N3 parity).

## What changed

- `SidebarView.collectionsSection` now hosts `CollectionsOutlineView`, framed to
  its reported content height (non-scrolling, inside the sidebar ScrollView).
- Removed the retired SwiftUI tree: `flattenedRows`, `collectionRow`,
  `chevronToggle`, `collectionTreeRow`, `collectionMenu`, `acceptReparent`,
  `handleCollectionDrop`, plus the `expandedFolderIDs` / `reparentTargetID` /
  `unNestTargeted` / `modifierReader` state (Spaces rows keep `treeRow`).
- Row context menu (New Subfolder / Rename / Move to / Delete) now lives in the
  coordinator; the two text-entry actions call back into the sidebar alerts.
- Added asset-drop parity to the coordinator: registers `.assetIDs`, retargets to
  the whole row, routes move/copy via the same `routeDrop`.

## Verification

Build + unit suites green. AppKit drag/disclosure/sizing/styling need in-app
verification (`/run`) — see the handoff checklist. Revertible: the SwiftUI tree
is in git history.

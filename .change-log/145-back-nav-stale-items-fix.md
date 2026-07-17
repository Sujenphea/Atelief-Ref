# 145 — Back navigation showed the wrong collection's items

## Summary

Navigating from one collection into another and pressing Back updated the
navbar/title to the popped-to collection but left the grid showing the *deeper*
collection's items. The shared `IngestionModel.items` is loaded per-screen by
`CollectionView`'s `.task(id: collectionID)`, which fires on a fresh push but
**not** when a covered view reappears after a pop (the view stayed alive and its
`collectionID` never changed). The title was correct because it derives from the
view's own `collectionID`; the grid was stale because nothing reloaded it.

Fix: make the **nav path the single owner** of "which collection is live."
`AppShellView` now loads the top collection's contents on every `nav.path`
change (push *and* pop) via `.onChange(of: nav.path, initial: true)`. The
per-view `.task` no longer loads contents — it only refreshes the drop-rail
covers. This removes the double-load on push as a side benefit (previously the
push triggered a load from the task; now there is exactly one load per
navigation).

## Files changed

- `AtelierRefs/AtelierRefs/AppShellView.swift` — added `syncActiveCollection` +
  `.onChange(of: nav.path, initial: true)` as the single loader.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — `.task(id:)` reduced to the
  cover refresh; no longer sets `selectedFolderID` / calls `loadContents`.

## Migration notes

None. `selectedFolderID` (the import target) is now set by the shell as the top
collection changes, matching the previous per-view behavior.

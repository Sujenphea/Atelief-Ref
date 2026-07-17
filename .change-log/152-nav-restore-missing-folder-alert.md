# 152 — Nav restore: no "folder no longer exists" alert on launch

## Summary

Fixes a regression from the nav-restore seeding (changelog set 145–148 era, commit
`d3cec63`): the app showed **"That folder no longer exists."** on *every* launch
when the last-opened collection had since been deleted.

`NavModel.path` is seeded with the last-opened collection, and `AppShellView` then
loaded that collection's items once `model.isReady` flipped. But it loaded
**unconditionally** — `loadContents(of:)` on a since-deleted id throws
`AtelierError.notFound`, which surfaces as the shared error alert. `ContentView`'s
prune cleared the stale *path* (so you still landed on the gallery), but the load
had already fired the alert.

Fix: load the seeded collection off `model.folders` (not `isReady`, which flips
*before* the folder list loads) and **only if it still exists**. When it's gone we
skip the load entirely and let the existing prune drop the path to the gallery —
silently. A genuinely-existing collection (root or subfolder — `listCollections`
returns all) still restores and loads its items.

## Files changed

### AtelierRefs
- `AppShellView.swift` — replaced the `.task(id: model.isReady)` seeded-load with an
  `.onChange(of: model.folders, initial: true)` that loads the seeded collection
  once, guarded by existence; added a `didLoadSeededCollection` one-shot flag.

## Migration notes

None. A stale `AtelierLastCollectionID` in `UserDefaults` now falls back to the
Collections gallery quietly instead of alerting.

## Verify

- Open a collection, quit, delete that collection's row out-of-band (or delete it
  then quit), relaunch → the app opens on the **Collections gallery** with **no**
  "That folder no longer exists." alert.
- Open a collection (or subfolder), quit, relaunch → it reopens on that collection
  with its items loaded (restore still works).

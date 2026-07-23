# 204 · Collection manual order — data foundation (043 Phase A)

## Summary

Adds a persisted manual sibling order to collections (`sort_index`), the data
foundation for drag-to-reorder in the sidebar tree (043 · decision 2B). Collections
previously had no position — every list was `(name, id)`-sorted, so a drag could
only reparent, never reposition. Now each parent's children carry a **dense,
gapless `0..<n`** order maintained by the service on create / delete / move, and
the sidebar tree + gallery display in that order.

This is Phase A of `.docs/043-nested-collections-ui-plan.md` (data only — no UI
drag yet; that's Phase C).

## What changed

- **Domain** (`Collection.swift`): added `sortIndex: Int` (default 0), column
  `sort_index`.
- **Migration v11** (`Migrator.swift`): additive `sort_index INTEGER NOT NULL
  DEFAULT 0`, then a deterministic back-fill giving each row its `(name, id)` rank
  within its parent group (roots share the `NULL` group) — so existing libraries
  keep their current visual order. Correlated-subquery back-fill (no window-function
  dependency). Composite index `index_collection_on_parent_sort_index`.
- **Service** (`AppServices.swift`):
  - `createCollection` appends (index = sibling count).
  - `deleteCollection` closes the gap in the former parent.
  - `moveCollection(id:toParent:index:)` — unified reparent **and/or** reposition:
    inserts at `index` (nil = append; clamped) in the destination group and
    renumbers it dense, and closes the old group's gap on a parent change. This one
    op backs the "Move to ▸" menu (append), same-parent reorder, and
    reparent-with-position. Subsumes the separately-planned `reorderCollections`
    (reorder = move within the same parent) — a DRY consolidation of the plan.
  - `childCollections` now orders by `(sort_index, name, id)`. `listCollections`
    keeps its `(name, id)` contract (the UI regroups + re-sorts per parent).
  - Private `childIDsOrdered` / `applyDenseOrder` helpers; renumbering uses a
    targeted column UPDATE so it does not bump `updated_at`.
- **UI order** (`IngestionModel.FolderNode.tree`, `CollectionTargets.galleryRoots`
  / `moveTargets.subfolders`): sort each sibling group by `sortIndex`, tie-broken
  by `(name, id)` via the new shared `CollectionTargets.byManualOrder`. The flat
  cross-tree `folderMoveTargets` list stays alphabetical (findability).

## Tests

- `ServicesCollectionOrderTests` (new, 11 tests, 9A): create-appends, delete-closes-
  gap, create-after-delete-is-dense, reorder-to-front / append, move-across
  (append + at index), index clamping, position-restoring inverse move (service
  half of undo), a longer mixed sequence stays dense, and the seeded Unsorted
  index.
- `MigrationV11Tests` (new): v11 back-fills a dense per-parent `(name, id)` order
  over a pre-v11 (through-v10) database.
- Pinned migration lists updated to include `v11` (`Migrator.registeredIdentifiers`
  + `MigrationAppendOnlyTests`).
- Full `AtelierCore` suite (440 tests) + app build + `CollectionTargetsTests` green.

## Migration notes

Additive and forward-only. Existing installs upgrade with one ALTER + a one-time
back-fill that reproduces the prior `(name, id)` display order, so nothing appears
to move. No API break: `moveCollection`'s new `index` parameter defaults to `nil`
(append), so existing callers (the "Move to ▸" menu path) are unchanged.

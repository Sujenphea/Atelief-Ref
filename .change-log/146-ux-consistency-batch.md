# 146 — UX consistency & safety batch

## Summary

First batch from the UX review (see `.docs/034-ux-consistency-overview.md`).
Targets the data-loss risks and cheap consistency guards.

- **Space delete is now confirmed + undoable.** Deleting a space used to run
  instantly with no confirmation and no way back — while asset delete had both. A
  board can hold hundreds of placements, so it now stages a confirmation dialog and
  registers a `⌘Z` undo that restores the whole board verbatim. The underlying
  assets are never touched (only placements), so restore is a verbatim re-insert.
- **Search failure is distinct from "no results."** A thrown query used to set
  `results = []`, rendering the same empty state as a genuine miss. A `queryFailed`
  flag now drives a distinct "Search failed" state.
- **"Add from Library" keeps picks across collection switches.** Changing the
  collection picker used to silently clear the selection; picks now accumulate in a
  `[UUID: Asset]` map. Added a per-collection **Select All / Deselect All**.
- **Element inspector commits on outside-click.** Dismissing the popover by clicking
  away used to discard every edit; it now commits pending edits (guarded so
  Done/Delete don't double-write or resurrect a deleted element).
- **Bulk sweeps confirm destructive actions.** Sweep **Cancel** and **Turn Off Bulk
  Import** now show a confirmation dialog first.
- **Empty-name guards.** New/Rename for spaces, collections, and subfolders disable
  their commit button when the name is empty/whitespace.

## Files changed

### AtelierCore
- `Services/DeletedSpaceBackup.swift` — new verbatim backup value (space + items).
- `Services/AppServices.swift` — `deleteSpaceRecoverable(id:)` and
  `restoreDeletedSpace(_:)` (mirror the asset-delete backup/restore pattern;
  idempotent, tolerant of a since-deleted cover/placed asset).

### AtelierRefs
- `IngestionModel.swift` — `pendingSpaceDeletion` state + `requestDeleteSpace` /
  `confirmSpaceDeletion` / `cancelSpaceDeletion`, with reversible undo/redo via the
  existing `registerReversible` + `enqueueUndoable` chain. Replaces the old
  fire-and-forget `deleteSpace`.
- `ContentView.swift` — shared space-delete confirmation dialog + `Bool` binding.
- `SpacesListView.swift` — Delete… stages the pending deletion; empty-name guards.
- `CollectionsGalleryView.swift` — empty-name guards (new/rename/subfolder).
- `LibrarySearch.swift` — `queryFailed` flag + distinct error state.
- `AddFromLibrarySheet.swift` — accumulate picks across collections; Select All.
- `ElementInspector.swift` — commit-on-dismiss with a `finished` guard.
- `BulkSweepsView.swift` — confirmations for sweep Cancel and Turn Off.

## Migration notes

None. `IngestionModel.deleteSpace(id:)` (fire-and-forget) is replaced by the staged
`requestDeleteSpace(id:name:)` → `confirmSpaceDeletion()` flow; the only caller was
`SpacesListView`. `services.deleteSpace(id:)` is retained (unused by the app now)
for callers/tests that want the non-recoverable path.

## Verify

- Spaces → context-menu Delete… → confirm → space gone → `⌘Z` restores it (with all
  placements). Redo (`⇧⌘Z`) deletes again.
- Search a query that errors → "Search failed" (not "No results").
- Add from Library → select in collection A, switch to B, select more → both kept;
  Select All toggles only the current collection.
- Edit a frame/text, click outside the popover → the edit persists.
- Bulk sweep Cancel / Turn Off → confirmation dialog appears first.

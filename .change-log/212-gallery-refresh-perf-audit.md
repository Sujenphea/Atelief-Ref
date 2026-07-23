# 212 · Gallery refresh perf audit (043 Phase F · 15B)

## Summary

Audit-only, no code change. 043 · 15B asked whether the nested-collections work
(subfolders → more collections) could turn the Collections/Home gallery refresh
paths into per-collection N+1 query storms. It does not — every path is already
set-based, running a fixed number of queries regardless of collection count or
nesting depth. Recorded here so the conclusion is on the record.

## What was checked

| Path | Queries | Verdict |
|---|---|---|
| `refreshFolders` → `listCollections()` | 1 | single fetch |
| `refreshCollectionCovers` → `collectionCovers(ids)` | 1 (`WHERE id IN (…)`) | batched |
| `refreshStackPreviews` → `collectionStackPreviews(…)` | 3 fixed (roots + `GROUP BY` count + `ROW_NUMBER()` window) | not N+1 |
| `refreshSpaces` → `spaceCovers(ids)` | 1 (`WHERE id IN (…)`) | batched |
| `refreshSpaceStackPreviews` → `spaceStackPreviews(…)` | 3 fixed (spaces + `GROUP BY` count + window) | not N+1 |

The stack-preview services deliberately use one window-function query
(`ROW_NUMBER() OVER (PARTITION BY collection_id …)`) to pull each collection's N
newest thumbnails in a single pass — the exact shape a naive implementation would
have done as one query per card. The model side already passes all ids to the
service in one call (`folders.map(\.id)`), so nothing loops on the app side
either.

## Conclusion

No change needed. Adding subfolders increases the ROW COUNT these queries scan,
not the NUMBER of queries; the covering indexes (incl. v11's
`index_collection_on_parent_sort_index`) keep the scans bounded. If the gallery
ever grows a RECURSIVE item count (subtree totals rather than direct counts),
revisit — that would add a recursive CTE, still one query, but worth a re-check.

## Status

043 phased build sequence complete: A/B (manual order + reparent) · C
(NSOutlineView sidebar) · D (route reconcile) · E (name-entry dedup) · F (this
audit). Remaining open items are product decisions, not build tasks: gallery-card
reorder scope, and duplicate-name policy.

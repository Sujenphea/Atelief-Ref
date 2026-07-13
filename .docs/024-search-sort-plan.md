# 024 — Search & Sort: Implementation Plan (feature 007)

Implements [`feature-todo/007-search-sort.md`](./feature-todo/007-search-sort.md).
Confirmed decisions this pass: **all of 007 in staged commits**; **global
per-asset view counter**; **tag vocabulary includes user + agent tags, visually
distinguished**. Spaces search stays deferred (recommended).

## Phases (one commit + changelog each)

### G1 — Search query layer (Core, pure) ✓ plan

- `TagMatch` (query-only enum, ServiceTypes): `.all` / `.any`.
- Extend `searchAssets(text:platform:tagIDs:tagMatch:collectionID:limit:after:)`.
  Defaults (`tagIDs: []`, `tagMatch: .all`, `collectionID: nil`) keep every
  existing caller source-compatible. New WHERE conjuncts compose with the
  existing platform/FTS/keyset seek:
  - `collectionID` → `id IN (SELECT asset_id FROM collection_item WHERE collection_id = ?)`.
  - tags `.any` → `id IN (SELECT asset_id FROM asset_tag WHERE tag_id IN (…))`.
  - tags `.all` → same subquery `GROUP BY asset_id HAVING COUNT(DISTINCT tag_id) = N`
    (dup-join-safe; exact set semantics, no FTS churn).
  - empty `tagIDs` → no tag conjunct.
- `tagVocabulary(prefix:limit:)` → `[Tag]` — case-insensitive prefix, ordered
  `name, source, id`, limit-clamped. Returns both sources; the `Tag.source`
  rides along so the UI distinguishes agent tags. `allTags()` convenience.

### G2 — Search UI (App)

- `LibrarySearchModel` (`ObservableObject`): `text`, `tokens: [TagToken]`,
  `suggestions`, `scope` (this collection / all), debounced `results:
  [AssetDetail]`, loading/empty state. Queries through `AppServices`.
- `.searchable(text:tokens:)` on the Collections gallery (global scope) and the
  Collection screen (collection scope + a This-collection/All toggle). Tokens =
  tag filters (suggested from `tagVocabulary`); typed text = FTS. **Tokens
  resolve to tag IDs — raw tag text is never sent to FTS.**
- Results reuse a thumbnail grid over `AssetDetail`; tapping opens the existing
  presentation-only `ItemDetailView` via an asset-scoped overlay (same shape as
  the Space path — no folder membership, no prev/next).

### G3 — Sort core (migration + reads)

- **Migration v5** (append-only, next slot): `asset.view_count INTEGER NOT NULL
  DEFAULT 0`, `asset.last_viewed_at TEXT`, `collection.sort_mode TEXT NOT NULL
  DEFAULT 'manual'`, `INDEX index_asset_on_view_count`. Pin `"v5"` in the
  registered list + the migration test.
- `SortMode` (Enums, persisted C5): `.manual` / `.newest` / `.mostViewed =
  "most_viewed"`. Add `Asset.viewCount`/`lastViewedAt` and
  `Collection.sortMode` (defaulted inits → source-compatible constructions).
- `collectionItems(in:sort:)` — collection-scoped **full array** (P16), so no
  cursor: ORDER BY per mode — `.manual` → `manual_order, id`; `.newest` →
  `created_at DESC, id DESC`; `.mostViewed` → `view_count DESC, created_at DESC,
  id DESC` (tie-break matters — view_count ties are the norm). Switching modes
  is non-destructive: `manual_order` is never touched. (The mode-tagged keyset
  cursor the spec calls for is reserved for a future *paged* search-sort;
  `searchAssets` keeps its single newest ordering. Documented, not built early.)
- `recordViews(_ ids:at:)` — one transaction, `view_count = view_count + 1,
  last_viewed_at = ?` per distinct id. `setCollectionSortMode(_:for:)` — persist
  + bump `updatedAt`, `.notFound` if absent.

### G4 — Sort UI + view coalescer (App)

- Toolbar sort menu on the Collection screen (Manual / Newest / Most viewed);
  drag-reorder disabled outside `.manual`. Selection persists via
  `setCollectionSortMode`; feed reloads with the new mode.
- Pure `ViewBumpCoalescer` — a `Set<UUID>` of pending ids flushed on
  detail-close / a short timer → one batched `recordViews`. **A view = Item
  Detail open only** (the deliberate signal), wired at the detail-open call site;
  never grid selection or canvas realization.

## Test strategy (mirrors 007 §Test strategy)

- Search: AND vs OR (0/1/2/3 tags), dup-join safety (`COUNT(DISTINCT)`),
  tag+text+platform+collection combined, keyset paging **with** a tag filter,
  unknown tagID → empty, user-vs-agent sources; vocabulary prefix + limit + both
  sources.
- Sort: each mode deterministic incl. tie-breaks; `recordViews` batch increment
  + `last_viewed_at`; sort_mode round-trip; manual order provably untouched by
  bumps and mode switches; migration identifier pinned + defaults on existing
  rows.
- Coalescer — pure: open×N collapses to one bump; flush on close/timer.

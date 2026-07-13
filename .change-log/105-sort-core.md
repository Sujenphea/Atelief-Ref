# 105 — Sort core: view tracking + per-collection sort mode (007 G3)

The core half of collection sorting: a new migration, two domain fields, the
per-mode read, and the view/sort writes. Pure `AtelierCore`; no UI yet (G4).

## Summary

- **Migration v5** (append-only, pinned in `registeredIdentifiers` + the
  migration test):
  ```sql
  ALTER TABLE asset ADD COLUMN view_count INTEGER NOT NULL DEFAULT 0;
  ALTER TABLE asset ADD COLUMN last_viewed_at TEXT;
  ALTER TABLE collection ADD COLUMN sort_mode TEXT NOT NULL DEFAULT 'manual';
  CREATE INDEX index_asset_on_view_count ON asset(view_count);
  ```
  Every added column is constant-defaulted, so existing rows migrate cleanly
  (verified: a pre-v5-shaped insert gets `view_count 0` / `last_viewed_at NULL`,
  and the v2-seeded Unsorted folder gets `sort_mode 'manual'`).
- **`SortMode`** (`Enums.swift`, persisted C5): `.manual` / `.newest` /
  `.mostViewed = "most_viewed"`.
- **`Asset.viewCount` / `.lastViewedAt`** and **`Collection.sortMode`** — added
  with defaulted inits, so every existing construction site stays
  source-compatible (no call-site churn).
- **`collectionItems(in:sort:)`** — the collection feed (full array, P16, so no
  cursor) gains a per-mode ORDER BY: `.manual` → `manual_order, id`; `.newest` →
  `asset.created_at DESC, asset.id DESC`; `.mostViewed` → `asset.view_count
  DESC, asset.created_at DESC, asset.id DESC`. The default `.manual` preserves
  prior behaviour. Switching modes never rewrites `manual_order` — provably
  non-destructive.
- **`recordViews(_:at:)`** — one transaction; each distinct id's `view_count +=
  1` and `last_viewed_at = at`. Unknown ids skipped, duplicates counted once,
  empty is a no-op. (A view = an Item Detail open — wired at the call site in
  G4.) **`setCollectionSortMode(_:for:)`** — persists + bumps `updatedAt`,
  `.notFound` if absent.

## Design notes

- **Global per-asset counter** (confirmed): one asset, many memberships → one
  counter. An asset viewed a lot ranks high in every folder (consistent with
  dedup). Per-collection counts would need counters on `collection_item` — not
  built.
- The spec's mode-tagged keyset cursor is **not** built: the collection feed is
  a full array (P16), so there is no cursor to mis-pair. `searchAssets` keeps its
  single newest ordering. A future *paged* search-sort can add the typed cursor
  then.

## Files changed

- `Persistence/Migrator.swift` — v5 migration + registered list.
- `Domain/Enums.swift` — `SortMode`.
- `Domain/Asset.swift`, `Domain/Collection.swift` — new defaulted fields.
- `Services/AppServices.swift` — `collectionItems(in:sort:)`, `recordViews`,
  `setCollectionSortMode`.
- Tests: `ServicesSortTests.swift` (7), `MigrationTests.swift` (+3 v5),
  pinned committed list → `…, "v5"`.

## Tests

Core **259** green (was 249, +10). Ingestion + Server rebuild clean against the
additive model change.

## Migration notes

Additive migration v5 runs automatically at launch. The v5 columns are backed up
(they live in the library DB) and covered by the 008 pre-migration snapshot.

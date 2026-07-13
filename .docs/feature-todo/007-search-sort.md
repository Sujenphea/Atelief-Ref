# 007 — Search & Sort: Tag/Text Search UI, Newest / Most-Viewed Sort

> Covers the "Extra" group: **search by tag** and **sort by newest, most viewed**.
> The search backend half-exists (FTS5 + tag services, zero UI); sort needs new
> columns and the app's first view-tracking.

## Current state

- `AppServices.searchAssets(text:platform:limit:after:)` (`AppServices.swift:539–588`):
  FTS5 over `source(title, author_handle, author_name)`, platform filter, keyset
  pagination on `(created_at DESC, id DESC)`. **No search UI anywhere.**
- Tag services complete + tested (`applyTag`/`removeTag`/`tags(for:)`,
  `AppServices.swift:596–658`; `asset_tag` with index) — entry UI is
  [006](./006-item-detail.md)'s job; the **query side** is this doc.
- Collection feed is `manual_order, id` only (`LibraryDatabase.collectionItemDetails`);
  drag-reorder persists via `setGridOrder`. `index_asset_on_created_at` exists — newest
  is cheap. **No view tracking of any kind** (verified).

## Search — options

### S1 — Structured tag filter; tags stay out of FTS — recommended
Add `tagIDs: [UUID]` + `tagMatch: .all/.any` (+ optional `collectionID` scope) to
`searchAssets` as WHERE conjuncts: `IN` for OR; AND via
`GROUP BY asset_id HAVING COUNT(DISTINCT tag_id) = N` subquery.

- ✅ Exact set semantics; no tokenizer fuzziness; composes with the existing
  platform/FTS/keyset conjuncts; no FTS churn on `applyTag`.
- ❌ Typed tag text doesn't fuzzy-match — the token UI resolves names → IDs (that's its
  job).

### S2 — Fold tag names into FTS
Needs hand-written triggers on `asset_tag` (tags are a join, not a `source` column —
GRDB's `synchronize(withTable:)` pattern doesn't apply), and AND-across-tags isn't
expressible in FTS. **Rejected — explicit over clever loses.**

### UI — S3 (with S1)
`.searchable(text:tokens:)` toolbar field: selected tokens = tag filters (suggestions
from a new `tagVocabulary(prefix:)` read, shared with 006's editor autocomplete); typed
free text = FTS. **Context-scoped**: global on the Collections screen, collection-scoped
on a Collection screen, with a "This collection / All" toggle. Results reuse the
existing grid.

**Recommendation: S1 + S3, default AND** (progressive narrowing is the reference-library
mental model; OR is an additive param later). Coordinate with
[003](./003-multi-kind-items.md): tweet text / link titles arrive via the new
`asset_fts` — `searchAssets` will union/branch two FTS sources; design the query builder
with that seam in mind but don't build it early.

## Sort — options

### Where the preference lives
- **P1 — `collection.sort_mode` column** (recommended): library data — persisted,
  exported, backed up, per-collection. Default `'manual'`.
- P2 — app-wide UserDefaults: not per-collection, invisible to backup/export. **Rejected.**
- P3 — per-collection UserDefaults keyed by UUID: orphans keys, outside the library.
  **Rejected.**

### View tracking
- **V1 — counter columns** (recommended): `asset.view_count INTEGER NOT NULL DEFAULT 0`
  + `asset.last_viewed_at TEXT NULL` (+ index on `view_count`). One UPDATE per view;
  `last_viewed_at` makes a future "recently viewed" sort free.
- V2 — `asset_view` event table: buys only time-windowed ranking (not a requirement),
  costs growth/GC/rollup. Honestly weighed and **rejected as over-engineering**; V1
  doesn't block adding it later additively.

### What counts as a view
**Item Detail open only** (the deliberate "I looked at this" signal — one call site,
006). NOT inspector/grid selection (arrow-key browsing would inflate counts), never
canvas/grid realization. Local-only data; never exported except with a full library
export.

### Write path
Coalesce bumps in a pure debounce helper (a `Set<UUID>` of pending IDs flushed on
detail-close or a short timer) → one batched `recordViews(_:at:)` through the write
funnel. Negligible against WAL.

### Feeds and cursors
`collectionItems(in: sort:)` with `SortMode`: `.manual` → `manual_order, id` (existing);
`.newest` → `created_at DESC, id DESC`; `.mostViewed` → `view_count DESC, created_at
DESC, id DESC`. **Each mode's keyset cursor must carry that mode's sort key** — a
mode-tagged cursor enum makes a cursor/ORDER-BY mismatch type-impossible (the classic
keyset drift bug; ties on `view_count` are the norm, so the tiebreak matters).
Switching modes is **non-destructive**: `manual_order` is untouched by `newest`/
`mostViewed`; switching back restores the drag order. Drag-reorder is disabled outside
`.manual` (it has no meaning there).

## Schema / migration impact

Search: **none**. Sort: one additive migration (next free slot — sequencing note in
[003](./003-multi-kind-items.md)):

```sql
ALTER TABLE asset ADD COLUMN view_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE asset ADD COLUMN last_viewed_at TEXT;
ALTER TABLE collection ADD COLUMN sort_mode TEXT NOT NULL DEFAULT 'manual';
CREATE INDEX index_asset_on_view_count ON asset(view_count);
```

New AppServices: `recordView(s)`, `setCollectionSortMode`, extended
`searchAssets(text:platform:tagIDs:tagMatch:collectionID:limit:after:)` (defaults keep
existing callers source-compatible), `allTags()` / `tagVocabulary(prefix:limit:)`,
`collectionItems(in:sort:)`.

## Phased implementation

1. **G1 (S) — search query layer.** Tag/collection conjuncts + vocabulary reads. Pure
   core.
2. **G2 (M) — search UI.** Token field on Collections + Collection toolbars (004 shell),
   scope toggle, results grid, empty/loading states.
3. **G3 (M) — sort core.** Migration + `recordView(s)` + `collectionItems(in:sort:)` +
   mode-tagged cursor + `setCollectionSortMode`.
4. **G4 (S) — sort UI + coalescer.** Toolbar sort menu on the Collection screen;
   view-bump coalescer wired to detail-open (006).

## Test strategy

- Search: AND vs OR set semantics (0/1/2/3 tags), dup-join safety
  (`COUNT(DISTINCT …)`), tag+text+platform+collection combined, keyset paging **with** a
  tag filter (no drift/repeat), unknown tagID → empty, agent-vs-user tag sources.
- Sort: each mode's ordering deterministic incl. tie-breaks; **per-mode keyset paging**
  (esp. pages of equal `view_count`); `recordViews` batch increments + `last_viewed_at`;
  sort_mode round-trip; manual order provably untouched by bumps and mode switches.
- Coalescer — pure unit tests (open×N collapses to one bump; flush on close/timer).
- Migration — identifier pinned; defaults verified on existing rows.

## Effort: **M (search) + M (sort)**

## Risks & edge cases

- Cursor/ORDER-BY mismatch is the one real correctness trap — the typed cursor kills it.
- Token field must never send raw tag text into FTS (silent miss); tokens resolve to IDs
  first.
- Most-viewed uses the **global** per-asset counter — an asset heavily viewed in folder A
  ranks high in folder B (consistent with dedup: one asset, many memberships).
  Per-collection counts would need counters on `collection_item` — heavier, not
  recommended.
- FTS query sanitization already exists (`ftsMatchQuery`, `AppServices.swift:887`) —
  reuse, don't fork.

## Settled decisions

- S1 structured filter + S3 token UI, default AND. P1 sort_mode column. V1 counters,
  view = detail-open only, non-destructive mode switching.

## Open questions

1. Global (recommended) vs per-collection view counts — confirm.
2. Agent-applied tags in the token vocabulary: include with a visual distinction, or
   user tags only? (Recommend include, distinguished — they're useful filters.)
3. Does the Spaces screen need search in v1, or Collections/Collection only?
   (Recommend defer.)

# 014 — Data core: read / search / tags API

**Chunk 6** (final) of the data-core build: the public READ / SEARCH surface on
`AppServices` (P16 bounded reads + FTS5 search) plus the minimal schema-reserved
tags apply/remove/list the agent interface needs. All reads return GRDB-free
public value types (A2).

## Summary

Reads route through a new private `read {}` funnel — the counterpart of the
chunk-5 `write {}` — running the op in a concurrent pool snapshot
(`database.pool.read`, NOT the serialized writer, A3) and mapping any throw to an
`AtelierError` (C7) so GRDB never crosses the boundary. Collection-scoped reads
return full arrays (P16); the library-wide `searchAssets` is bounded by a clamped
`limit` and a keyset cursor. Search is backed by the `source_fts` FTS5 table.

## Decisions realized

- **A2** — every public read returns GRDB-free value types. The internal joined
  `FetchableRecord` was renamed `CollectionItemDetail` → **`CollectionItemRow`**
  (so the name is free) and a public, GRDB-free `CollectionItemDetail`
  (`item`/`asset`/`source`) is mapped from it. New internal `AssetSourceRow`
  decodes the asset+source join; the public `AssetDetail` is mapped from it.
- **P14** — `collectionItems(in:)` is the single joined read (CollectionItem ⋈
  Asset ⋈ Source, one round-trip, no N+1), mapped to `[CollectionItemDetail]`.
- **P16** — collection-scoped reads (`collectionItems`) return the full array;
  `searchAssets` clamps `limit` to `1...500` and pages by keyset cursor. Reads
  carry metadata only — never blob bytes.

## Public surface (all `async throws`, GRDB-free)

- `listCollections() -> [Collection]` — ordered by `name`, then `id` (stable).
- `getCollection(id:) -> Collection` — `.notFound` if absent.
- `collectionItems(in:) -> [CollectionItemDetail]` — P14 joined read, ordered
  `manual_order` then `id`; `.notFound` if the collection is absent.
- `getAsset(id:) -> AssetDetail` — asset + its provenance; `.notFound` if absent.
- `searchAssets(text:platform:limit:after:) -> [AssetDetail]` — FTS5 + filters +
  keyset paging.
- `applyTag(_:to:source:) -> Tag` / `removeTag(_:from:source:)` /
  `tags(for:) -> [Tag]`.
- New value types: `CollectionItemDetail`, `AssetDetail`, `AssetPageCursor`.

## FTS5 MATCH sanitization

`AppServices.ftsMatchQuery` splits the user text on whitespace, wraps each term
as a quoted FTS5 string (doubling any embedded `"` per FTS5's escaping rule), and
joins the quoted terms with spaces (implicit AND): `brass wood` → `"brass"
"wood"` (both must match). Quoting neutralizes every FTS5 operator (`*`, `:`,
`^`, `-`, `(`, `NEAR`, `OR`, a lone `"`, emoji, …) as literal text, so arbitrary
input can never form malformed MATCH syntax — verified by a "nasty inputs don't
throw" test. The match runs as a subquery mapping `source_fts.rowid` →
`source.rowid` → `source.id`, filtering the base asset query by `source_id IN
(…)`.

## Keyset cursor

`AssetPageCursor(createdAt:id:)` carries the sort key of the previous page's last
row. Ordering is `created_at DESC, id DESC` (stable, since `id` is unique). With
a cursor the request filters to rows strictly after it:
`created_at < cursor.createdAt OR (created_at == cursor.createdAt AND id <
cursor.id)`. Dates bind to the same millisecond-precise sortable TEXT the column
stores (C5), and the read-back date round-trips exactly, so equality on ties
holds — no OFFSET, no drift or repeats as new assets land. A pagination test
pages a 13-row set in pages of 4 and asserts exact coverage (== the single-shot
oracle order), no overlap, no gaps, and that `limit` is honored + clamped.

## Files changed

- `Persistence/LibraryDatabase.swift` — renamed internal
  `CollectionItemDetail` → `CollectionItemRow`; added internal `AssetSourceRow`.
- `Services/ServiceTypes.swift` — added public `CollectionItemDetail`,
  `AssetDetail`, `AssetPageCursor`.
- `Services/Validation.swift` — added `tagName` (trim + non-empty).
- `Services/AppServices.swift` — added the `read {}` funnel; the read methods;
  `searchAssets` + `ftsMatchQuery`; `applyTag` / `removeTag` / `tags(for:)`.
- `Tests/AtelierCoreTests/ServicesReadTests.swift` *(new)* — list/get ordering +
  empties + `.notFound`; the joined `collectionItems`; `getAsset`.
- `Tests/AtelierCoreTests/ServicesSearchTests.swift` *(new)* — FTS title/author
  match + miss, multi-term AND, platform filter, `text == nil` listing, keyset
  pagination coverage, limit clamping, sanitization.
- `Tests/AtelierCoreTests/ServicesTagsTests.swift` *(new)* — apply create/link +
  idempotency, user-vs-agent distinctness, tag sharing, `.notFound`, empty-name
  rejection, idempotent `removeTag` (source-respecting), `tags(for:)` ordering.

## Verification

- `swift test` — **134 tests in 23 suites pass** (chunks 1-5 included; +32 new).
- `grep -rl "import GRDB" Sources/AtelierCore/Domain/` → none ("OK: Domain
  GRDB-free"). The public read/search/tags signatures expose only value types
  (`Collection`, `CollectionItemDetail`, `AssetDetail`, `Tag`, `AssetPageCursor`,
  `Platform`, `TagSource`) — no `FetchableRecord`/GRDB type leaks (A2).

## Migration notes

None — additive. The internal `CollectionItemDetail` → `CollectionItemRow` rename
is internal-only (the public type now owns that name). The chunk-4
`PersistenceTests` joined-read suite is unaffected (it uses the returned values'
`.item`/`.asset`/`.source`, not the type name). This completes the data-core
build sequence (006 step 2).

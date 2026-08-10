# 366 — One Gallery-Card Query, Not Two Copies

[023](../.docs/feature-todo/023-archive-and-second-library.md) phase **A0**. A
pure refactor with no behaviour change, done before the archive shelf rather
than after, because the shelf's predicate would otherwise be added in eight
places that have to agree.

## The duplication

`collectionCovers` / `spaceCovers` were the same query over two parent tables.
`collectionStackPreviews` / `spaceStackPreviews` were the same *pair* of queries
— a count aggregate and a `ROW_NUMBER()` window — differing only in the child
table, its foreign key and its recency column. `spaceStackPreviews`'s own doc
comment already called itself "the space analog of `collectionStackPreviews`".

Adding `archived_at IS NULL` naively means four count queries and four hash
queries edited to match. The failure mode when one is missed is exactly the risk
023 names: a card reading "12 items" while fanning 9.

So the predicate now has one place to go, per side.

## What was extracted

Two private statics in the `Private query helpers` section of `AppServices`:

- `covers(in:table:ids:)` — the cover-hash lookup, parameterized by parent table.
- `stackPreviews(in:parentIDs:childTable:parentColumn:recencyColumn:limit:)` —
  returns `(counts:hashes:)` for parents the caller has already fetched in its
  own order.

Table and column names are **parameters interpolated into the SQL, not a query
DSL** — the simplest thing that removes the duplication. They are compile-time
literals from the two call sites and never user input; every id and the limit
still bind as arguments. Both helpers say so in their doc comments, because that
is the invariant a future third caller could break.

Parent fetching stays at the call sites, where it differs for real: roots
ordered `name, id` with the Unsorted opt-in, versus spaces ordered `sort_index,
created_at DESC, id`.

## The count aggregate is now scoped to the parents being rendered

`SELECT collection_id, COUNT(*) FROM collection_item GROUP BY collection_id` had
no `WHERE`. It counted every collection in the library on every Home render and
Swift discarded the non-roots. The hash query was unscoped in the same way. Both
now take `WHERE <parent> IN (…)` over ids that are already in hand a few lines
above — not new machinery.

Output is identical, so **no test can distinguish this**; it is a cost change,
not a behaviour change. Stated plainly rather than dressed up as a guarded fix.
Its value is prospective: archive would otherwise turn a full aggregate into a
full indexed join.

## Tests

652 pass, up from 649. The three new ones are the pairing guard 023 asks for —
`itemCount` and `recentBlobHashes` come from two queries that must agree about
which rows exist:

- collections: with every item byte-backed and under the limit, the count and
  the fan are the same number.
- collections: a subfolder's items stay out of its root's count and fan.
- spaces: the same pairing, plus two boards asserting neither bleeds into the
  other.

Verified non-vacuous by mutation — applying the exact mistake A1 risks (a
predicate on the fan query but not the count query, `AND a.is_favorite = 1`)
fails both new pairing tests along with 9 existing assertions. Reverted.

## Files changed

- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift`
- `AtelierCore/Tests/AtelierCoreTests/ServicesMoveTests.swift`
- `AtelierCore/Tests/AtelierCoreTests/ServicesSpaceTests.swift`

## Migration notes

None. No schema change, no public API change — the four public functions keep
their signatures and their results. `AtelierRefs` builds untouched.

# 012 — Data core: persistence layer

**Chunk 4** of the data-core build: GRDB record conformances for the domain
types, a `DatabasePool`/WAL-backed store, and the single P14 joined read. No
public App Services / write funnel yet (chunk 5) — everything here is `internal`.

## Summary

The domain value types are made persistable through GRDB via extension files
(decision A1) so the `Domain/` structs stay GRDB-free. A `LibraryDatabase`
opens/migrates a WAL store and exposes the one joined read that loads a
collection's items with their asset + source in a single query (P14, no N+1).

## Decisions realized

- **A1** — conformances live in `Persistence/<Type>+GRDB.swift`; Domain stays
  GRDB-free (verified by grep).
- **A2** — store, records, migrator all `internal`; only the (future) App
  Services surface is public.
- **A3** — `LibraryDatabase` wraps a `DatabasePool` (WAL, concurrent reads +
  serialized writer); `final class … Sendable` (no in-memory mutable state yet).
- **C5** — UUIDs stored as lowercased `uuidString` TEXT (via a per-record
  `databaseUUIDEncodingStrategy(for:)` forwarding to `RecordConvention`); dates
  as GRDB's default millisecond-precise sortable UTC text.
- **P14** — `collectionItemDetails(in:)` uses GRDB associations
  (`including(required:)`) to load CollectionItem ⋈ Asset ⋈ Source in one
  round-trip, ordered by `manual_order` then `id`.
- **T9** — `makeTempDatabase()` builds an isolated, migrated temp-file
  `DatabasePool` per test (real WAL, faithful to A3), with `cleanup()`.

## Column naming: explicit CodingKeys, not a snake_case strategy

The first approach (GRDB `.convertToSnakeCase`/`.convertFromSnakeCase` column
strategies) was abandoned: Foundation's two conversions are **not inverses for
all-caps acronyms** — `originalURL` encodes to `original_url`, but
`original_url` decodes back to `originalUrl`, so `originalURL`, `coverAssetID`,
`collectionID`, `assetID`, `tagID` silently lost their columns on read. Fixed by
giving each domain struct an explicit `CodingKeys` mapping every property to its
exact snake_case column (explicit over clever). The strategies were removed; only
the UUID *value* strategy remains.

## rawMetadata: JSONValue as a database scalar

GRDB's automatic nested-Codable handling misreads a single-value-container enum
like `JSONValue` (a stored object decoded back as `.bool(false)`). Fixed by
conforming `JSONValue: DatabaseValueConvertible` (in `Persistence/`, so Domain
stays GRDB-free): it stores as JSON TEXT and reads back by decoding that text —
`DatabaseValueConvertible` takes precedence over Codable recursion in GRDB's row
coder.

## Files changed

- `Persistence/AtelierRecord.swift` *(new)* — `AtelierRecord` protocol +
  `RecordConvention` (UUID-as-lowercased-text strategy, defined once).
- `Persistence/{Asset,Source,Collection,CollectionItem,Tag}+GRDB.swift` *(new)* —
  record conformances (`databaseTableName`, UUID strategy, `belongsTo`
  associations for P14). `Tag+GRDB` also conforms `AssetTag`.
- `Persistence/JSONValue+GRDB.swift` *(new)* — `DatabaseValueConvertible`
  (JSON TEXT storage).
- `Persistence/LibraryDatabase.swift` *(new)* — `DatabasePool` store, `read`/
  `write` access, the P14 `collectionItemDetails(in:)` joined read +
  `CollectionItemDetail` row.
- `Domain/{Asset,Source,Collection,CollectionItem,Tag}.swift` *(modified)* —
  added explicit `CodingKeys` (Foundation Codable; Domain stays GRDB-free).
- `Tests/AtelierCoreTests/TestSupport/TestDatabase.swift` *(new)* — `T9`
  temp-file Pool helper.
- `Tests/AtelierCoreTests/PersistenceTests.swift` *(new)* — round-trips (all
  types, populated; UUID-as-text; acronym columns; nested rawMetadata), FK
  enforcement through the store, and the P14 joined read (correctness + scope).

## Verification

- `swift test` — **73 tests in 17 suites pass** (chunks 1-3 included).
- `grep -rl "import GRDB" Sources/AtelierCore/Domain/` — none (Domain GRDB-free).

## Migration notes

None — additive. The store is `internal`; nothing public yet. The chunk-5 write
funnel will wrap `LibraryDatabase.write {}` to enforce the invariants (C6/C8) and
expose the public `AppServices` surface.

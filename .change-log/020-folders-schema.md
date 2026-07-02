# 020 — Folders: v2 schema + domain (nested folders)

**Chunk 1** of the folders build (`.docs/008-folders-overview.md`). Adds the
`AtelierCore` schema + domain groundwork for nested folders: a self-referential
parent link on `collection`, its index, and the SEEDED protected "Unsorted"
folder. NO services (chunk 2) and NO UI (chunk 3).

## Summary

### Domain — `Collection` (`Domain/Collection.swift`)
- New `public var parentCollectionID: UUID?` (decision F1) — a folder's parent;
  `nil` = a root folder. Added as the LAST init parameter with a `nil` default so
  existing `Collection(id:name:description:coverAssetID:createdAt:updatedAt:)`
  call sites still compile unchanged.
- New CodingKeys case `case parentCollectionID = "parent_collection_id"` — the
  GRDB record (`Collection+GRDB.swift`, unchanged) maps it automatically.
- New `public static let unsortedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!`
  (decision F3) — the fixed well-known id of the seeded default-import folder.
  Protected (undeletable / unrenamable / unreparentable) — those guards land in
  `AppServices` in chunk 2.

### Migration — v2 (`Persistence/Migrator.swift`, append-only)
`registeredIdentifiers` → `["v1", "v2"]`; v1 body untouched. The v2 body:

```sql
-- 1. self-referential parent FK (nullable; NULL default is required for an
--    ALTER-added FK column). ON DELETE CASCADE recurses through descendant
--    folders (F1/F4).
ALTER TABLE collection
    ADD COLUMN parent_collection_id TEXT
        REFERENCES collection(id) ON DELETE CASCADE;

-- 2. access path for "children of a folder" (P13).
CREATE INDEX index_collection_on_parent_collection_id
    ON collection(parent_collection_id);

-- 3. seed the protected Unsorted root folder (F3). Fixed lowercased id, literal
--    timestamps (a migration can't call Date()), parent NULL.
INSERT INTO collection
    (id, name, description, cover_asset_id, created_at, updated_at, parent_collection_id)
VALUES
    ('00000000-0000-0000-0000-000000000001', 'Unsorted', NULL, NULL,
     '2024-01-01 00:00:00.000', '2024-01-01 00:00:00.000', NULL);
```

### FK-cascade approach (F4)
Used the **plain `ALTER TABLE … ADD COLUMN … REFERENCES … ON DELETE CASCADE`** —
no table-rebuild needed. SQLite *does* enforce this ALTER-added FK here (GRDB
keeps `PRAGMA foreign_keys` on). The subtree-cascade test is the guardrail and it
passes: given P → C → G folders + a `collection_item` filing an asset into C,
deleting P removes P, C, and G (the parent FK cascade recurses) and C's membership
(the existing `collection_item.collection_id` cascade), while the asset and source
survive as library rows.

## Files changed
- `AtelierCore/Sources/AtelierCore/Domain/Collection.swift` — `parentCollectionID`
  field + CodingKey + `unsortedID` constant.
- `AtelierCore/Sources/AtelierCore/Persistence/Migrator.swift` — v2 migration
  (`createV2Schema`) + `registeredIdentifiers = ["v1", "v2"]`.
- `AtelierCore/Tests/AtelierCoreTests/MigrationTests.swift` — pinned list →
  `["v1", "v2"]`; new suites: v2 shape (nullable TEXT column, index, FK pragma),
  seeded Unsorted (F3), subtree cascade (F4), and `Collection` record round-trip
  with a non-nil / nil `parentCollectionID`.
- `AtelierCore/Tests/AtelierCoreTests/ServicesReadTests.swift` — three existing
  `listCollections` tests updated to account for the now-seeded Unsorted folder
  (fresh store holds exactly Unsorted; the ordered/tie tests exclude it).

## Verification
- `swift test` (AtelierCore): **142 tests in 27 suites passed** (was 134; +8 new
  folder tests, 3 read tests adjusted).
- `swift build` (AtelierIngestion): **Build complete** — the added `Collection`
  field (defaulted) didn't break dependents.

## Migration notes
Additive + append-only. Existing `Collection(...)` call sites compile unchanged
(new param defaults to `nil`). Databases in the field replay only v2, which ALTERs
`collection` and seeds Unsorted. Any code that lists collections must now expect
the protected Unsorted folder to be present — the chunk-2 services will expose
`unsortedFolderID` and enforce its protection.

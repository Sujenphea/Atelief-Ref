# 021 — Folders: AppServices folder operations

**Chunk 2** of the folders build (`.docs/008-folders-overview.md`). Adds the
`AtelierCore` service surface for nested folders over the existing collection
methods (folders ARE collections — no new entity). NO UI (chunk 3). Builds on
the v2 schema + domain (chunk 1, `020-folders-schema.md`).

## Summary

### Errors — `AtelierError` (`Services/AtelierError.swift`)
- `case protectedCollection(id: UUID)` — rename / delete / move attempted on the
  protected Unsorted folder (decision F3).
- `case folderCycle` — a reparent that would make a folder its own
  ancestor/descendant (decision F6).
Both `public` and `Equatable` like the rest; the write funnel's `init(mapping:)`
passes them through unchanged (they're already `AtelierError`).

### Services — `AppServices` (`Services/AppServices.swift`)
- **`createCollection(name:description:parent:)`** — new trailing
  `parent parentID: UUID? = nil`. When non-nil, asserts the parent exists
  (`.notFound`) inside the funnel and sets `parentCollectionID`; `nil` keeps the
  existing root-folder behaviour. Existing no-parent call sites compile
  unchanged (defaulted).
- **`renameCollection`** — guard at the top: `id == Collection.unsortedID` throws
  `.protectedCollection(id:)` (F3). Rest unchanged.
- **`deleteCollection`** — same protected guard (F3). Subtree (descendant
  folders + memberships) CASCADEs at the DB level (F4) — descendants are NOT
  hand-deleted.
- **`moveCollection(id:toParent:)`** (new) — reparent a folder. Rejects Unsorted
  (`.protectedCollection`); the folder must exist (`.notFound`); a non-nil new
  parent must exist (`.notFound`) and pass the cycle check; `nil` ⇒ becomes a
  root; bumps `updatedAt`.
- **`childCollections(of:)`** (new, read) — DIRECT children only, ordered by
  `name` then `id`. `nil` ⇒ root folders (`parent_collection_id IS NULL`, incl.
  the seeded Unsorted).
- **`unsortedFolderID: UUID`** (new) — computed accessor returning
  `Collection.unsortedID`, so the app has the default import target without
  importing the domain constant path.

### Cycle prevention (F6)
`moveCollection` walks UP the ancestor chain from the proposed `newParentID` via
`parent_collection_id` (one `select(Column("parent_collection_id"), as:
UUID?.self)` per hop). If the walk reaches `id`, then `id` is an ancestor of
`newParentID` — i.e. `newParentID` is `id` itself or a descendant of it — so the
move would form a cycle and throws `.folderCycle`. A self-move
(`newParentID == id`) is caught on the very first step. The walk is bounded by
the tree depth and terminates at a root (`nil` parent).

## Files changed
- `AtelierCore/Sources/AtelierCore/Services/AtelierError.swift` — two new cases.
- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` — `parent:` on
  create, protected guards on rename/delete, `moveCollection`,
  `childCollections`, `unsortedFolderID`.
- `AtelierCore/Tests/AtelierCoreTests/ServicesFolderTests.swift` — new suite
  (10 tests): create-with-parent (+ missing parent, root nil), protected-Unsorted
  guards + Unsorted exists, reparent (+ move-to-root, missing parent), cycle
  prevention (self / child / grandchild reject, sibling move legal), subtree
  delete with surviving asset, childCollections roots-vs-direct, ingest into a
  created folder.

## Verification
- `swift test` (AtelierCore): **152 tests in 28 suites passed** (was 142; +10
  new folder-service tests).
- `swift build` (AtelierIngestion): **Build complete** — the added
  service methods didn't break dependents.

## Migration notes
Additive + source-compatible. `createCollection`'s new `parent:` is a defaulted
trailing parameter, so existing callers compile unchanged. Any code that
renames/deletes/moves a collection must now handle `.protectedCollection` for the
Unsorted id, and `moveCollection` may throw `.folderCycle`.

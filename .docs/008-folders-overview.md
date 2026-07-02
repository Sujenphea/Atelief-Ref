# 008 — Folders: Overview (decisions + plan)

> A user-facing organisation feature (not a numbered build-order item, but it
> realises the MVP's "Library + Collections" surface). Imports land in a generic
> uncategorised default place, and the user can create nested folders to organise
> into. Builds on the data core ([006](./006-datacore-overview.md)) and the
> ingestion Import UI ([007](./007-ingestion-overview.md)).

Branch: `feat/folders` (off `feat/ingestion`).

## What we're building

Folders **are collections** — no new entity. We add hierarchy, a protected
default folder, and the app UI to create/organise/browse. The data core already
supports most of it (many-to-many membership, `ingest(into:)` targets any
collection); the gaps are the parent link, the tree UI, and a bit of services.

## Decisions (from interactive clarification)

- **F1 — Nested folders via `parent_collection_id`.** A v2 migration adds a
  nullable `parent_collection_id TEXT REFERENCES collection(id) ON DELETE
  CASCADE` + an index. Nesting was explicitly deferred in the MVP plan but the
  model was designed for it (a `Collection` owns its id) — this is that additive
  step. `NULL` parent = a root folder.
- **F2 — Boards-style membership (many-to-many, filing ADDS).** An image can live
  in several folders at once (keeps the "same asset on multiple boards" canvas
  premise intact). Consequence: **Unsorted does not auto-empty** — an import
  stays in Unsorted even after being added elsewhere; the user can remove it from
  Unsorted manually.
- **F3 — Protected "Unsorted" root folder.** A collection with a FIXED
  well-known id, seeded by the v2 migration, that is undeletable + unrenamable +
  unreparentable and is the guaranteed default import target. Enforced in
  `AppServices` (reject delete/rename/move for the Unsorted id).
- **F4 — Delete a folder → delete the whole subtree.** Handled by the
  `ON DELETE CASCADE` on `parent_collection_id` (recurses through descendant
  folders) + the existing cascade on `collection_item.collection_id` (removes
  their memberships). Assets themselves survive as library rows. No blob side
  effects, so the DB cascade is safe (consistent with the 17A rationale).
- **F5 — Opening a folder shows DIRECT items only.** A folder lists items filed
  directly into it; subfolders appear as navigable children (Finder-like). This
  is already how `AppServices.collectionItems(in:)` behaves. A recursive
  "include subfolders" aggregate is a later toggle.
- **F6 — Reparent with cycle prevention.** `moveFolder` rejects making a folder
  its own ancestor/descendant (no cycles), and rejects moving Unsorted.

## Build sequence (one agent per chunk, sequential)
1. **Schema v2 + domain** — migration adding `parent_collection_id` (+ index, FK
   `ON DELETE CASCADE`) and SEEDING the protected Unsorted folder (fixed id,
   literal timestamps); `Collection.parentCollectionID` field + CodingKeys;
   `Collection.unsortedID` constant. Append-only guard → `["v1","v2"]`; migration
   + cascade + seed tests.
2. **AppServices folder operations** — `createFolder(name:parent:)`,
   `renameFolder`, `moveFolder(id:newParent:)` (cycle prevention, F6),
   `deleteFolder` (subtree via cascade), `childFolders(of:)` / `folderTree()`,
   `unsortedFolderID`, protected-Unsorted guards (F3). Invariant + failure tests
   (create nested, move, cycle rejection, subtree delete, protected guards).
3. **App UI** — a folder-tree sidebar (create / new-subfolder / rename / delete,
   reparent via move) in a `NavigationSplitView`; the Import tab gains a target
   folder picker defaulting to Unsorted (replacing the hardcoded "Inbox");
   selecting a folder shows its direct items (thumbnail grid) + subfolders.
   `IngestionModel` updated. App builds; manual runtime verification.

## Verification
`swift test` green across `AtelierCore` (v2 migration, folder services) and
`AtelierIngestion`; the app builds; a manual run shows the folder tree, folder
creation/nesting, importing into a chosen folder, and Unsorted as the protected
default.

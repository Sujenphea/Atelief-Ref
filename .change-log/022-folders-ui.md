# 022 — Folders: App UI (folder tree + browsing + retargeted import)

**Chunk 3 (final)** of the folders build (`.docs/008-folders-overview.md`). The
SwiftUI glue over the finished v2 schema (chunk 1, `020-*`) + `AppServices`
folder operations (chunk 2, `021-*`). Adds a nested folder-tree sidebar
(create / subfolder / rename / delete / move), folder browsing (direct items +
subfolders), and retargets the Import flow to the selected folder (default the
protected Unsorted). No package changes.

## Summary

### `IngestionModel` (`AtelierRefs/AtelierRefs/IngestionModel.swift`) — rewritten
- STOPPED seeding an "Inbox" collection. The default import target is now
  `services.unsortedFolderID` (guaranteed by the v2 migration). Added
  `@Published var selectedFolderID: UUID` defaulting to `Collection.unsortedID`.
- Folder-tree state: `@Published var folders: [Collection]` (all collections via
  `listCollections()`) plus a `FolderNode` value type (`id`, `name`,
  `children?`) and `FolderNode.tree(from:)` that groups by `parentCollectionID`
  (roots = nil parent, name-ordered, empty child sets → `nil` for leaf display).
  `folderTree` / `refreshFolders()` exposed.
- Folder actions (each calls the service, refreshes the tree, surfaces thrown
  `AtelierError` via `@Published var lastError: String?`): `createFolder`,
  `renameFolder`, `deleteFolder`, `moveFolder`. Rename/delete/move guard against
  `unsortedFolderID` in the model too (the service also rejects them). Deleting
  the selected folder falls the selection back to Unsorted.
- Folder contents: `@Published var items: [CollectionItemDetail]` +
  `@Published var subfolders: [Collection]`; `loadContents(of:)` uses
  `collectionItems(in:)` + `childCollections(of:)`. `thumbnail(for:)` loads an
  `NSImage` from the `MediaStore` 512 tier via
  `thumbnailURL(hash:size:fileExtension:"jpg")`.
- Import runs through the `IngestCoordinator` with inputs built `into:` the
  CURRENT `selectedFolderID`; after a batch → `refreshFolders()` +
  `loadContents(of: selectedFolderID)`.
- `AtelierError` → friendly message mapping for the alert (protected / cycle /
  invalid name / not found).

### `FolderTreeView` (`AtelierRefs/AtelierRefs/FolderTreeView.swift`) — new
- Sidebar `List(selection:)` + `OutlineGroup(children:)` over `folderTree`,
  single-selection bound to `selectedFolderID` (reloads contents on change).
- Toolbar **New Folder** (root). Per-folder context menu: **New Subfolder**,
  **Rename**, **Move to…** (every other folder as parent, plus **Top Level**),
  **Delete** — Rename / Move / Delete DISABLED for Unsorted (rendered with a
  `tray` icon). Name entry via a small `NameSheet` modal.

### `LibraryView` (`AtelierRefs/AtelierRefs/LibraryView.swift`) — new
- `NavigationSplitView`: sidebar = `FolderTreeView`; detail = selected folder's
  subfolders (navigable capsule chips) + a `LazyVGrid` thumbnail grid of its
  direct `items`, plus the import affordances (dashed drop target + Paste,
  targeting `selectedFolderID`) and a progress / item-count indicator.
  `lastError` shown via `.alert`. Drop→`IngestInput` conversion folded in from
  the old `ImportView`.

### `ContentView` (`AtelierRefs/AtelierRefs/ContentView.swift`)
- Kept the `TabView`; **Canvas** tab unchanged. Second tab renamed **Import →
  Library**, now hosting `LibraryView`.

### Removed
- `AtelierRefs/AtelierRefs/ImportView.swift` — replaced by `LibraryView`; its
  drop/paste plumbing migrated over.

## Files changed
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — rewritten.
- `AtelierRefs/AtelierRefs/FolderTreeView.swift` — new.
- `AtelierRefs/AtelierRefs/LibraryView.swift` — new.
- `AtelierRefs/AtelierRefs/ContentView.swift` — Import tab → Library tab.
- `AtelierRefs/AtelierRefs/ImportView.swift` — deleted.

## Verification
- `AtelierIngestion` package: `swift test` → **58 tests in 8 suites passed**
  (a stale `.build` first produced a linker error against the pre-chunk-2
  `createCollection` symbol; a clean rebuild is green).
- App: `xcodebuild … -scheme AtelierRefs -destination 'platform=macOS' build`
  → **BUILD SUCCEEDED**. Project uses file-system-synchronized groups
  (objectVersion 77), so the new files are picked up automatically; no pbxproj
  edits.

## Manual runtime steps (GUI can't be auto-tested)
1. Launch → **Library** tab. Sidebar shows **Unsorted** (tray icon), selected.
2. Toolbar **New Folder** → name it → appears as a root row.
3. Right-click that folder → **New Subfolder** → nests under it (disclosure
   triangle appears).
4. Select a folder, drop / Paste an image → the thumbnail grid + count update;
   the item is filed into that folder (Unsorted also retains its own imports).
5. Right-click **Unsorted** → Rename / Move / Delete are DISABLED (and the
   service throws `.protectedCollection`, shown via the alert, if forced).
6. Right-click a folder → **Move to… → Top Level** (or another folder);
   attempting a cycle (into its own descendant) raises the alert.

## Migration notes
App-only. The default import target moved from a seeded "Inbox" collection to the
protected Unsorted folder; existing libraries keep their "Inbox" as an ordinary
root folder (no longer special). No data migration required.

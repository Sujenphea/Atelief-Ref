# 004 — Navigation Redesign: Top Bar (Collections / Collection / Spaces)

> Covers the "Top bar" group. Settled direction (user): **replace the 3-tab shell**
> (Canvas / Library / Sweeps) with a top-bar navigation — Collections (gallery of all
> collections) → Collection (one collection's items) → Spaces (list → open a space).
> Sweeps and import become toolbar/menu-level. This is the foundation the
> [005 Spaces](./005-spaces.md) and [006 Item Detail](./006-item-detail.md) work plugs
> into.

## Current state

- `ContentView.swift:13–68` — `TabView` (Canvas/Library/Sweeps) over one shared
  `@StateObject IngestionModel`; the app-shell `.alert` and the shared destructive-delete
  `.confirmationDialog` live here.
- `AtelierRefsApp.swift` — bare `WindowGroup { ContentView() }`; no `.commands`.
- `IngestionModel.selectedFolderID` does double duty: folder open in Library AND folder
  feeding the Canvas — nav state fused into an 840-line view model.
- `LibraryView.swift` — `NavigationSplitView { FolderTreeView } detail:` header +
  dropZone + subfolderChips + grid. The Collection detail surface is fully built and
  reusable.
- Covers exist in the model but not the UI: `Collection.coverAssetID` +
  `AppServices.setCollectionCover` (`AppServices.swift:112`) are unused, and no read
  resolves a cover thumbnail.

## Options

### O1 — NavigationStack + small NavModel + toolbar breadcrumb — recommended
Root (unpushed) = Collections gallery; `NavModel.path: [Route]` with
`Route = .collection(UUID) | .spaces | .space(UUID)`, plus `presentedItemID` for the
detail overlay. Top bar = `.toolbar` (breadcrumb, Spaces entry, import menu, sweeps
status).

- ✅ Native back/forward, `⌘[`, window title via `.navigationTitle`; drill-down matches
  the gallery → collection → space vision; existing grid/chips reused wholesale;
  deep-linking is just a path value.
- ❌ Push semantics vs the lightbox detail overlay need one deliberate decision (006
  resolves it: overlay, driven by `presentedItemID`); the persistent folder tree goes
  away.

### O2 — 3-column NavigationSplitView (keep the tree)
- ✅ Least churn; power-user tree always visible.
- ❌ Contradicts the settled "Collections gallery as a screen" direction; no natural
  home for a full-bleed Space canvas; keeps `selectedFolderID` as god-state. **Rejected.**

### O3 — Hand-rolled enum root switch + custom top bar
- ✅ Maximally explicit.
- ❌ Re-implements back/forward/title/keyboard by hand — anti-DRY, more surface to test.
  **Rejected.**

## Recommendation — O1, with a firm "engineered enough" line

Introduce `NavModel: ObservableObject` holding **route state only** (`path`,
`presentedItemID`). All data loading (folders, items, import, capture, sweeps) stays in
`IngestionModel`. **Do not decompose IngestionModel in this epic** — it mixes ~8 concerns
and splitting it is a separate XL refactor with real regression risk and thin UI-level
test cover. When 005 lands, each open Space gets its own `SpaceModel` instead of growing
IngestionModel further.

Other placements:
- **Folder tree**: dropped from the primary flow. Gallery shows root collections as
  cover cards; drilling in reuses `subfolderChips` + grid; a **breadcrumb** (pure
  ancestor-chain helper over the flat `[Collection]`, mirroring `FolderNode.tree`) covers
  depth. Folder CRUD moves to card context menus + a toolbar "+" (reusing the existing
  `createFolder/renameFolder/moveFolder/deleteFolder` model calls).
- **Sweeps**: a toolbar status affordance (live count/progress) opening `BulkSweepsView`
  in a sheet.
- **Browser Capture popover**: unchanged, relocated to the app-level toolbar.
- **Import affordances**: the Collection screen keeps its dropZone + ⌘V; a Space gets its
  own drop target (005).
- **Shared alert + delete confirmation**: move from `ContentView` to the new root so the
  "errors surface anywhere" property (G1 fix) is preserved — regression-test this
  manually.

## Schema / migration impact

**None.** One new read for the gallery: `collectionCovers(_ ids:) -> [UUID: String]`
(collection → cover `blob_hash`), or fold the cover hash into an extended
`listCollections` projection. Cover *setting* already exists (`setCollectionCover`) —
surface it as "Set as Cover" on a grid item's context menu.

## Phased implementation

1. **P1 (M) — shell swap.** `NavModel.swift` (route enum + pure push/pop helpers) + new
   `AppShellView` root replacing the TabView. Collection screen = today's `LibraryView`
   detail extracted into `CollectionView`. Spaces route temporarily wraps `CanvasScreen`
   bound to `selectedFolderID` until 005-E2 replaces it. Gallery can initially be a
   simple list of root collections. `.commands` for back (`⌘[`) in `AtelierRefsApp`.
   Files: `NavModel.swift` (new), `AppShellView.swift` (new), `ContentView.swift`
   (shrinks), `LibraryView.swift` (splits), `AtelierRefsApp.swift`.
2. **P2 (S–M) — gallery.** `CollectionsGalleryView`: cover-card `LazyVGrid` using the new
   cover read; card context menus (CRUD, Set as Cover); Unsorted card treatment.

## Test strategy

- `NavModel` route reducer (push/pop/replace/clamp) — pure unit tests in the
  `GridNavigation.swift` pattern.
- Breadcrumb ancestor-chain builder (flat `[Collection]` → root→leaf chain, cycle-safe) —
  pure, tested like `FolderNode.tree`.
- `collectionCovers` read — `AppServices` test beside the existing read tests.
- Views compile-only (repo convention); extend the existing XCUITest smoke to the new
  shell (launch → gallery → open collection → back).

## Effort: **M**

## Risks & edge cases

- Moving the shared alert/confirmation must not regress G1 (errors visible from any
  screen).
- macOS NavigationStack/title quirks (verify on macOS 26 early in P1).
- Losing the persistent tree hurts deep hierarchies — breadcrumb + chips + "Move to…"
  menus are the mitigation; watch real usage.
- `selectedFolderID` semantics change: "no collection open" (gallery) is a new state the
  model must tolerate (currently defaults to Unsorted).
- Window `minWidth: 960` was sized for the 3-pane split (`ContentView.swift:29–32`) —
  revisit for the new shell.

## Settled decisions

- Full nav redesign (user). O1 NavigationStack + NavModel. No IngestionModel
  decomposition in this epic. Gallery replaces the persistent tree.

## Open questions

1. Should a tree view survive anywhere (e.g. an optional sidebar toggle on the Collection
   screen), or is gallery + breadcrumb + chips the complete navigation story?
   (Recommend: ship without; add a toggle only if depth navigation hurts in practice.)
2. Unsorted in the gallery: pinned first card (recommended) or hidden behind a filter?
3. Persist/restore `NavModel.path` across relaunch? (Recommend: restore last collection
   only — cheap and covers the common case.)

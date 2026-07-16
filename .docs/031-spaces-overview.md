# 005 — Spaces: First-Class Entity + Freeform Tools (Frame / Text / Shapes)

> Covers the "Spaces" group. Settled direction (user): a Space is **its own first-class
> entity** — the canvas↔folder link is removed, you can create many spaces, mix items
> from any collection, and use Freeform-style tools: frames, text, shapes. Plugs into
> [004](./004-navigation-redesign.md)'s `.spaces`/`.space(id)` routes.

## Current state

- Canvas is folder-bound: `CanvasContent(items:store:)` (`CanvasContent.swift:46`) maps
  the selected folder's `[CollectionItemDetail]` to tiles; placement persists
  per-membership via `setCanvasPlacement` → `collection_item.canvas_x/y/w/h/z`
  (`AppServices.swift:283`).
- The renderer's two stable seams are exactly where a Space plugs in: `TileProvider`
  (geometry) + `TileImageSource` (content). `Tile` is pure geometry (id, x/y/w/h/z).
- `CanvasEngine.sync()` (`CanvasEngine.swift:228`) assumes image content (pooled layers,
  culling, LOD, decode scheduling — benchmark-gated at ~4.6 ms/frame). Selection and
  badges are already **sibling CALayers outside the pool** (`CanvasEngine.swift:37,47`) —
  the precedent for vector overlays.
- `CanvasHostView` owns events; `mouseDown` always means select/drag — no tool modes.

## Entity — options

### O1 — One `space` + one discriminated `space_item` table — recommended
`space(id, name, created_at, updated_at)`;
`space_item(id, space_id FK CASCADE, kind, asset_id NULL FK CASCADE, x, y, w, h, z,
style TEXT NULL, created_at, updated_at)` + indices on `space_id`, `asset_id`.

- ✅ One read path, one placement writer; the nullable `asset_id` FK cascades **only**
  asset rows when an asset is deleted — freeform rows are untouched. Mirrors how
  `collection_item` already unifies membership + placement.
- ❌ One table serves two shapes of row (asset vs element) — the `kind` discriminator
  must be validated (asset rows require `asset_id`, element rows forbid it).

### O2 — `space_item` (assets) + separate `space_element` (freeform)
Cleaner typing, but two tables/read-paths/writers for one canvas — double surface for no
behavioural difference. **Rejected (DRY).**

### O3 — Space = a Collection with a type flag
Inherits folder semantics a space must not have (nesting, protected Unsorted, membership
dedup). Overloading is the opposite of explicit. **Rejected.**

### Existing `canvas_*` columns
Left **dormant** (append-only migrations cannot drop them). **No automatic data
migration** of folder canvas layouts into spaces — pre-release, those placements are
ephemeral arrangement. Instead: an optional **"New Space from this collection"** action
seeds a space from the folder's current layout. An escape hatch, not a fragile one-time
migration.

## Freeform tools — options

### T1 — Rasterize elements to images (reuse the pooled path)
Text re-rasterizes per zoom tier and per keystroke. **Rejected** as primary.

### T2 — Native vector CALayers
`CAShapeLayer` (frames/shapes), `CATextLayer` (text) as sibling layers outside the pool —
crisp at any zoom, near-free to composite.

### T3 — Hybrid — recommended
Images keep the untouched pooled/culled/LOD/decode path. Frames/shapes = `CAShapeLayer`.
Text = `CATextLayer` for display + a **transient `NSTextView` overlay only during active
editing** (commit to `style` JSON on end-edit).

**Perf story vs the 120fps budget:** the scale problem is images (thousands, hence the
pool). Freeform elements number in the dozens per board — one persistent vector layer
each, culled by the same `TileCuller` via world frames. Text re-layout happens on
edit-commit, never per frame. The image path's benchmark-gated 4.6 ms is untouched; add
a benchmark case with many vector elements as the regression guard.

## Recommendation & v1 scope line

O1 + T3. **Minimal credible v1 = Space entity + asset placement + FRAMES + TEXT +
basic undo.** Defer shapes (rect/ellipse/line/arrow), snapping, grouping, and
frame-as-group semantics to a later phase — arrows especially are disproportionate
geometry (arrowheads, endpoint handles). Frames and text are the two highest-value
Freeform/Figma primitives and exercise both new code paths (vector layer + text overlay).

A freeform editor without undo feels broken — include create/move/delete/restyle undo in
v1 via `UndoManager` inverses registered at the view-model layer, each paired with its
`AppServices` call. Flag: undo across async writes needs care (serialize through the
model).

**"Add from any collection":** primary = an in-Space **"Add from Library"** sheet
(multi-select across collections → justified-rows flow-in, reusing `CanvasContent`'s
layout math); secondary = **"Add to Space…"** context menu on grid/detail items.
Cross-screen drag is deferred (can't see both screens in a push-nav shell).

## Schema / migration impact

New append-only migration (next free slot — see the sequencing note in
[003](./030-multi-kind-items-overview.md)): `space` + `space_item` tables + indices; new domain
types `Space`, `SpaceItem`, `SpaceItemKind`, `ElementStyle` (Codable/Sendable) + GRDB
records mirroring `CollectionItem+GRDB.swift`; identifier appended to
`Migrator.registeredIdentifiers` + the pinned test.

AppServices surface (all through the existing write/read funnel):
`createSpace / renameSpace / deleteSpace / listSpaces / getSpace`,
`addAssetToSpace(assetID:to:placement:)`, `addElement(to:kind:geometry:style:)`,
`setSpaceItemPlacement` (mirrors `setCanvasPlacement`), `updateSpaceItemStyle`,
`removeSpaceItem`, `spaceItems(in:) -> [SpaceItemDetail]`.

## Phased implementation

1. **E1 (M) — core entity.** Migration + domain + services + tests. No UI. **Runs in
   parallel with 004's shell work.**
2. **E2 (M–L) — asset spaces UI.** `SpaceModel` (per-open-space view model — deliberately
   NOT more IngestionModel), `SpaceView` reusing `CanvasView`, `SpaceContent` (a
   space-backed `TileProvider`/`TileImageSource`, refactored from `CanvasContent`),
   Spaces list screen (004 route), "Add from Library" sheet, "New Space from this
   collection" seeding. Ships first-class spaces with zero renderer changes.
3. **E3 (L) — frames + text.** Tool palette (select/frame/text); `CanvasHostView` tool
   mode + `onCreateElement(kind, worldRect)` callback; vector sibling layers in
   `CanvasEngine`; `NSTextView` edit overlay; element persistence + undo.
4. **E4 (M, later) — shapes.** rect/ellipse/line/arrow, snapping, grouping as demand
   dictates.

## Test strategy

- Migration + services: the full existing discipline (table shape suite, cascade tests —
  deleting an asset vacates its space placements; deleting a space cascades items;
  discriminator validation).
- Renderer pure helpers, tested like `TileCuller`/`CanvasTransform`: topmost-at-point
  hit-testing across kinds, drag-to-create rect normalization, frame containment ("which
  items are inside frame F"), z-ordering, `ElementStyle` JSON round-trip.
- `SpaceContent` mapping tests mirroring `CanvasContentMappingTests`.
- Benchmark case: board with many vector elements stays inside the frame budget.
- CA host + SwiftUI: compile-only (repo convention); manual pass for text-edit overlay
  coordinate mapping under pan/zoom.

## Effort: **L for v1 (E1–E3); XL if E4 + full undo/snapping are included**

## Risks & edge cases

- **Renderer seam creep** — `CanvasEngine`/LOD/decode assume images; vector tiles must
  cleanly bypass pool + decode. Keep them entirely outside the recycled path.
- `NSTextView` overlay ↔ canvas coordinate mapping under live pan/zoom is the fiddliest
  UI work in the epic.
- `CanvasContent` → `SpaceContent` is a real refactor of load-bearing code (the folder
  canvas keeps working until E2 replaces it — see open Q3).
- Same asset twice in one space: fine (space_item has its own id) — decide whether the
  UI allows it deliberately.
- Open-space live refresh when an asset is deleted elsewhere (FK cascade handles data;
  the view needs the change-notification path, mirroring `handleRemoteCapture`).

## Settled decisions

- First-class entity, canvas↔folder link removed (user). O1 schema, T3 renderer, v1 =
  frames + text, no auto-migration of folder layouts.

## Open questions

1. **Frames v1**: visual labeled rects only, or contain-and-move-children (Figma group
   semantics)? Recommend visual-only in v1 — containment queries exist for later.
2. Space covers for the list screen (reuse the collection-cover pattern)? Recommend yes,
   trivial once the list exists.
3. What happens to the **folder Canvas tab feature** after E2 — remove folder-canvas
   entirely (settled direction implies yes), or keep a read-only "arrange this folder"
   view during a deprecation window?
4. Background grid / snap-to-grid in v1? (Recommend no — E4 territory.)

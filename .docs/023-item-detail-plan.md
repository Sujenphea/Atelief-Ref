# Item Detail — Completion Plan

Kind: `plan`. Finishes the item-detail feature whose page shipped in `084`
(design: [022-item-detail-design](./022-item-detail-design.md)). Three small
phases remain; each is an independent, shippable commit.

## Where it stands

`ItemDetailView` (full-window overlay over a collection) shipped: media area
(full-res image / inline `VideoPlayer`), prev/next, and a `DetailSidebar` with
metadata + provenance + source actions. What the feature still lacks:

- **F1 — Componentize / route the overlay.** The overlay is driven by a *local*
  `@State showDetail` in `CollectionView` (`CollectionView.swift:26,40`), while
  `NavModel.presentedItemID` exists but is unused (`NavModel.swift:39`, "Reserved
  for 006"). `DetailSidebar` is one 170-line private struct — no seam for a new
  section. This is the enabling refactor for F2 and F3.
- **F2 — Tags editor (the substantive gap).** Backend CRUD is complete but
  **unwired**: `AppServices.applyTag` (`:857`), `removeTag` (`:890`),
  `tags(for:)` (`:905`), plus `Tag` / `AssetTag` / `TagSource`. Zero callers in
  `AtelierRefs/`. This is the app's **first tags UI**.
- **F3 — Open on Enter / double-click (grid + canvas).** The grid opens detail on
  a *single*-click `Button` (`CollectionView.swift:157`); there is no
  `onTapGesture(count: 2)` and `.onKeyPress` covers only arrows (`:190-193`), no
  `.return`. A Space board tile has **no** path to detail at all.

## Decisions (confirmed)

1. **Grid click semantics (F3).** *Keep single-click = open* (unchanged from
   today), and **additionally** bind Return to open the selected item. No change
   to the existing tap behaviour; F3 is purely additive on the grid.
2. **Canvas invocation scope (F3).** Double-click an *asset* tile on a Space
   opens that asset's detail **if** tile→asset→detail resolves as a thin lookup;
   frame/text tiles are ignored (no asset). If it needs more than a thin lookup,
   ship grid Return now and split the canvas path into **F3b**.

## F1 — Componentize + route through `NavModel`

**Goal:** make "which item's detail is open" shared route state (so the grid and
the canvas can both open it) and give the sidebar a clean seam for the tags
section.

- **`NavModel`**: keep `presentedItemID: UUID?` as the single source of truth for
  the overlay (it already exists). Add nothing new; just start *using* it.
- **`CollectionView`**: delete the local `@State showDetail`. Present the overlay
  on `nav.presentedItemID != nil && model.selectedItem != nil`; the grid cell
  sets `nav.presentedItemID = detail.item.id` (F3 changes *when*); Back/Escape
  sets it back to `nil`. The existing auto-dismiss guard (`selectedItem != nil`)
  is preserved.
- **`ItemDetailView`**: extract `DetailSidebar`'s three sections into their own
  small subviews in the same file — `MetadataSection`, `ProvenanceSection`,
  `ActionsSection` — so `DetailSidebar` becomes a thin `VStack` of sections.
  Pure mechanical split (no behaviour change); this is where F2 inserts
  `TagsSection`.
- **Verify:** build; overlay still opens/closes exactly as before; prev/next,
  Escape, and auto-dismiss-on-delete all unchanged. No new tests (refactor).

## F2 — Tags editor

**Goal:** view, add, and remove an item's tags from the detail sidebar; the
app's first tags surface.

- **`IngestionModel`** (new model surface, mirrors the existing async funnel at
  `IngestionModel.swift:444/662`):
  - `@Published private(set) var selectedTags: [Tag] = []`.
  - `loadTags()` — `services.tags(for: selectedItem.asset.id)`; called from
    `select(_:)` and after each mutation so the chips stay live.
  - `addTag(_ name: String)` — `services.applyTag(name, to: assetID,
    source: .user)` then reload; empty/whitespace is rejected by
    `Validation.tagName` inside the service (surface `AtelierError` via the
    existing `lastError` alert).
  - `removeTag(_ tag: Tag)` — `services.removeTag(tag.name, from: assetID,
    source: tag.source)` then reload.
  - Reset `selectedTags` to `[]` when selection clears / on video-or-image alike
    (tags are per-asset, not kind-specific).
- **`TagsSection`** (new subview in `ItemDetailView.swift`, inserted into
  `DetailSidebar` above `ActionsSection`):
  - A wrap of tag chips (name + a small `xmark` remove button per chip). User
    tags and agent tags are visually distinguished (agent tags get a subtle
    badge/tint) since `source` already separates them and agent work must stay
    reviewable.
  - A `TextField("Add tag…")` committing on Return → `model.addTag`; clears on
    success.
  - Empty state: the field alone (no "no tags" noise).
- **Tests** (`AtelierRefsTests`, real temp `AppServices`, the SpaceUndoTests
  pattern): add→appears in `selectedTags`; duplicate add is idempotent (one
  chip); remove→gone; whitespace-only add throws and leaves tags unchanged.
- **Verify:** build; open an item → add "reference", "hero" → chips appear and
  persist across prev/next and reopen; remove one; relaunch shows them (DB-backed).

## F3 — Open on Enter / double-click

**Goal:** detail is reachable by keyboard and double-click, from the grid and
(asset tiles on) a Space.

- **Grid (`CollectionView`)** — per decision 1 (keep single-click open, add
  Return; purely additive):
  - Grid cell `Button` action is unchanged (still `open(detail)` on click).
  - Add `.onKeyPress(.return)` on the focusable grid → open the *selected* item.
  - `open(_:)` helper (used by click and Return): `model.select(detail);
    nav.presentedItemID = detail.item.id`.
- **Canvas (Space board)** — **deferred to F3b** (the thin-lookup escape hatch of
  decision 2 fired). `SpaceView.onActivateTile` already routes video→QuickLook and
  frame/text→inspector; an image-asset double-click currently falls through to
  nothing — that is the gap. But opening the *detail page* there is **not** a thin
  lookup: `ItemDetailView` is structurally bound to `IngestionModel`'s
  collection-scoped `selectedItem`, `items` (prev/next), and folder actions
  (`removeFromFolder`, …). A space asset has a `SpaceItemDetail` (asset + source)
  but **no `CollectionItem` membership**, so a correct presentation needs
  `ItemDetailView` decoupled to accept an explicit detail (+ optional prev/next
  set) — a refactor beyond F3's scope. **F3b** carries that decouple + the
  canvas double-click.
- **Tests:** the open-invocation is UI-gesture wiring (hard to unit-test);
  cover the pure bits — `open(_:)` sets `presentedItemID`, and the existing
  overlay-dismiss path. Extend the XCUITest smoke only if cheap.
- **Verify:** build; grid single-click still opens, and Return opens the selected
  item; Escape returns; arrow-nav + drag-reorder still work; double-click an
  asset tile on a Space opens its detail (or F3b noted as deferred).

## Sequence & commits

Three commits, F1 → F2 → F3 (F1 unblocks both). Each with a `.change-log/`
entry (next indices `094+`). Suggested subjects (≤80, project format):

- `refactor: item-detail - route overlay via NavModel, split sidebar`
- `feat: item-detail - tags editor in the detail sidebar`
- `feat: item-detail - open the detail page on Return from the grid` (F3;
  canvas split to F3b)
- `refactor: item-detail - decouple ItemDetailView; open from Space canvas` (F3b,
  not yet built)

## Out of scope

- Tag-based *filtering / search* across the library (a later surface; F2 is the
  per-item editor only).
- Agent-written tags UX beyond visual distinction (the agent interface is its own
  epic).
- Image zoom/pan (F4 in the old numbering) — remains parked; not requested here.

# Item Detail — UI Redesign Plan

Kind: `plan`. Reshapes the item-detail screen (`ItemDetailView`) to the Figma
"Item Detailed" frame (`Atelier-Ref`, node `6:4`). Builds on the shipped page
(design: [022-item-detail-design](./022-item-detail-design.md), completion:
[023-item-detail-plan](./023-item-detail-plan.md)). Split into independent,
shippable phases.

## Target (Figma `6:4`)

- **Top bar** — pill **Back** (left) + centered **`N / count`** pager in a
  bordered pill. No zoom controls, no title in the bar.
- **Right panel (298pt)** — three sections:
  - **Data** — `Saved` (dd/MM/yyyy) + `Dimensions` (`w px × h px`). Only these.
  - **Source** — `Platform`, `Author`, `Title`, full-width **Visit** button (↗).
  - **Details** — **Name** field, **Note** field, **Collections** chips
    (`Add +` / removable `×` pills), **Tags** chips with a ✦ add affordance.
- **Bottom** — centered 5-thumbnail **filmstrip** (deferred, see below).
- Chips: bordered rounded-6px pills — `#2C2C30` bg, `rgba(255,255,255,.08)`
  border. Header 20pt `ink #F2F1EE`; rows/labels 12pt `ink-secondary #9A9A9E`.

## Confirmed decisions

1. **Name / Note** — new **persisted** `Asset` fields (model + migration + save).
2. **Collections** — **editable** chips; fan membership into the detail read.
3. **Actions block** (Full Res / Reveal / Copy Link / Remove / Delete) — kept but
   moved into a top-bar **overflow (⋯) menu**; not shown in the panel.
4. **Data section** — match Figma exactly: `Saved` + `Dimensions` only.
5. **Source** — collapse to a **Visit** button; drop the Handle row + raw-URL text.
6. **Tags ✦ icon** — a **manual user add-tag** affordance (no auto-tag/LLM service
   exists; none is built).
7. **Filmstrip** — **deferred** to a separate task (needs neighbour thumbnail load;
   `Palette.filmstrip` already reserved). **Built** by
   [099](./099-mac-backlog-plan.md) · P9
   ([480](../.change-log/480-the-page-shows-its-neighbours.md)) — and the reservation
   did not survive: `Theme.Colors.filmstrip` was **deleted** in
   [352](../.change-log/352-floating-bars-one-system.md) once the top bar stopped using
   it. The strip is drawn on `mediaBackdrop`.
8. **Top bar** — match Figma; zoom controls move to an **image overlay**, title
   removed.

## Phase 1 — Model + storage (`AtelierCore`)

**Goal:** persist Name/Note and expose collection membership on the detail read.

- **`Asset`** (`Domain/Asset.swift`): add `name: String?`, `note: String?`
  (+ CodingKeys `name` / `note`, init params, defaults `nil`).
- **Migration v10** (`Persistence/Migrator.swift`): two ALTERs —
  `ALTER TABLE asset ADD COLUMN name TEXT;` / `... note TEXT;`. Append `"v10"`
  to `registeredIdentifiers`. (Additive, no rebuild — matches v5.)
- **`AppServices`** funnel methods:
  - `setName(_:for:)` / `setNote(_:for:)` — trim, empty→`nil`, update the row.
  - `collections(for assetID:)` — the asset's collection memberships (reverse
    lookup over `collection_item`). Fetched by the detail store on open, **not**
    fanned into `CollectionItemDetail` — that keeps it off the hot grid read
    (no N+1). Membership editing reuses the existing `addAssets` / `removeAssets`
    / `listCollections`.
- The new `name`/`note` columns decode automatically through the Codable
  `Asset` record (default `.allColumns` selection), so `CollectionItemRow` /
  `AssetSourceRow` need no change.
- **Tests** (`ServicesMoveTests` / new): round-trip name/note; membership
  add/remove; migration applies on a v9 DB.

## Phase 2 — Detail store (`AtelierRefs`)

**Goal:** one place the three hosts (collection, Space, search) get
Name/Note/Collections, reusing the per-asset store already bound at the right
lifecycle in all three.

- **Extend `AssetTagsStore`** (already `bind(to:)`-driven in every host — zero new
  wiring): publish `collections` + `allCollections`, load them in `refresh`, and
  add `setName` / `setNote` (bound assetID → funnel) and `addToCollection` /
  `removeFromCollection` (→ `addAssets`/`removeAssets`, reload).
- **Name/Note** are seeded in the view from `asset.name`/`asset.note` (the
  presentation-only contract already passes `asset`); the local draft is the
  edit source of truth, committed through the store — so no per-asset name/note
  state is needed in the store.

## Phase 3 — Right panel (`ItemDetailView.swift`)

**Goal:** rebuild `DetailSidebar` to Data / Source / Details.

- **`Chip`** — new shared bordered-6px pill (label + optional `+`/`×` trailing),
  replacing capsule `TagChip`. Used by Collections + Tags. Agent tags keep the ✦.
- **`MetadataSection` → `DataSection`** ("Data"): `Saved` + `Dimensions` only.
- **`ProvenanceSection`** ("Source"): Platform / Author / Title + Visit button;
  drop Handle + raw-URL rows.
- **`DetailsSection`** (new, "Details"): Name field, Note field (bordered pill
  `TextField`s wired to the store), Collections chips (`Add +` picker), Tags
  chips (moved here) + ✦ add affordance.
- Remove `ActionsSection` from the panel (relocated in Phase 4).

## Phase 4 — Top bar + actions (`ItemDetailView.swift`)

**Goal:** match the Figma bar; keep every action reachable.

- Pill **Back** + centered bordered **`N / count`** pager.
- **Zoom controls** move to a floating overlay on `mediaArea` (image only).
- **Overflow (⋯) `Menu`** (trailing): Open Full Resolution, Reveal in Finder,
  Copy Source Link, Remove from Folder, Delete — from the existing
  `ItemDetailActions`, each hidden when its closure is nil.

## Phase 5 — Tokens + changelog

- `Theme.swift`: section-header / row / chip surface + border tokens; panel 298.
- Changelog `.change-log/200-item-detail-redesign.md`.

## Deferred

- **Bottom filmstrip** — 5 neighbour thumbnails; own task (thumbnail-load work,
  ~~`Palette.filmstrip` reserved at `Theme.swift:39`~~ — that token was deleted in
  [352](../.change-log/352-floating-bars-one-system.md) on 2026-08-09; this line outlived
  it). **No longer deferred:** built by [099](./099-mac-backlog-plan.md) · P9 as
  `DetailFilmstrip`, five run neighbours through the shared `ThumbnailPipeline`
  ([480](../.change-log/480-the-page-shows-its-neighbours.md)).

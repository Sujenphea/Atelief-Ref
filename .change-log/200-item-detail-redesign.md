# 200 — Item Detail UI redesign

Reshapes the item-detail screen to the Figma "Item Detailed" frame
(`Atelier-Ref`, node `6:4`). Plan + decisions:
[.docs/041-item-detail-redesign-plan.md](../.docs/041-item-detail-redesign-plan.md).

## Summary

- **Right panel** rebuilt into three sections (Figma):
  - **Data** — Saved (`dd/MM/yyyy`) + Dimensions (`w px x h px`) only.
  - **Source** — Platform / Author (`Name (@handle)`) / Title + a full-width
    **Visit ↗** button; the raw-URL and Handle rows are gone.
  - **Details** — new editable **Name** and **Note** fields, **Collections**
    chips (Add-menu + removable), and **Tags** chips (moved here) with a ✦ manual
    add affordance.
- **Chips** restyled to bordered rounded-6px pills (`Theme.Colors.field` +
  `hairline`), shared by Collections and Tags via a new `DetailChip`.
- **Top bar** now Back (pill) + centered `N / count` pager only. **Zoom controls**
  moved to a floating overlay on the media; the source title is dropped. The
  former in-panel **Actions** block (Open Full Resolution, Reveal in Finder, Copy
  Source Link, Remove from Folder, Delete) moved to a trailing **overflow (⋯)
  menu** — nothing lost.
- **Name / Note are persisted**: new `Asset.name` / `Asset.note` columns
  (migration **v10**) + `AppServices.setName` / `setNote`.
- **Collections membership** surfaced in the detail panel:
  `AppServices.collections(for:)` (reverse lookup, kept off the grid read),
  edited through the existing `addAssets` / `removeAssets`.

## Files changed

**AtelierCore**
- `Domain/Asset.swift` — `name` / `note` fields (+ CodingKeys, init).
- `Persistence/Migrator.swift` — migration **v10** (`ALTER TABLE asset ADD
  COLUMN name/note`), appended to `registeredIdentifiers`.
- `Services/AppServices.swift` — `setName`, `setNote`, `collections(for:)`.
- `Tests/…/ServicesDetailFieldsTests.swift` — new (name/note round-trip,
  membership reverse lookup).
- `Tests/…/MigrationTests.swift` — pinned committed list → `v10`; applied-ids
  compared as a set (grdb_migrations orders `v10` lexically between `v1`/`v2`).
- `Tests/…/MigrationTagNormalizeTests.swift` — seeds v8-era asset rows via raw
  SQL (the current `Asset` record now carries v10 columns absent at v8).

**AtelierRefs**
- `ItemDetailView.swift` — top-bar rewrite (pill Back, pager, overflow menu,
  media-overlay zoom); `DetailSidebar` → Data / Source / Details; new
  `VisitButton`, `DetailField`, `CollectionsField`, `TagsField`, `DetailChip`;
  `DetailSection` / `DetailRow` retokenized; `DataSection` trimmed.
- `AssetTagsStore.swift` — broadened to also load `collections` /
  `allCollections` and expose `setName` / `setNote` / `addToCollection` /
  `removeFromCollection` (bound at the existing per-asset lifecycle).
- `AtelierRefsTests/AssetTagsStoreCollectionsTests.swift` — new (bind loads
  memberships + library list; add/remove; the last-membership **re-home to
  Unsorted**; `onMembershipChanged` fires).
- `AtelierRefsTests/NavModelTests.swift` — updated two route-intent tests stale
  since the sidebar refactor (`openSpaces` removed; top-level nav moved from
  `path` to `sidebarSelection`). Unrelated to this feature; fixed to unblock the
  test build.
- `CollectionView.swift`, `SpaceView.swift`, `LibrarySearch.swift` — pass the new
  collections / name / note bindings into `ItemDetailView`.

## Migration notes

- **Schema v10** is additive (two nullable TEXT columns, no rebuild). Existing
  rows read `name`/`note` as `NULL` (the "unnamed / no note" state). The pinned
  append-only migration guard was updated to include `v10`.
- No design-token changes: `Theme` already carried the Figma roles
  (`sectionTitle` 20pt, `label` 12pt, `field`/`hairline`, `Radius.chip`).

## Collections-chip fixes (root-cause pass)

Three issues in the Details → Collections chips, investigated and fixed:

1. **"Cosmetic, not functional" (the real bug).** Add/remove went straight
   through `AssetTagsStore → AppServices`, bypassing `IngestionModel` — the DB
   row was written and the chip list refreshed, but the collection grid, sidebar
   counts, and stack previews (read from `model`) never did, so the edit didn't
   show up behind the overlay. Fix: `AssetTagsStore.onMembershipChanged` callback,
   fired after each add/remove; `CollectionDetailHost` wires it to a new
   `IngestionModel.reloadAfterMembershipChange()` (refresh folders + reload the
   current folder — the `contentsVersion` bump also drives auto-dismiss when the
   shown item leaves the current folder, matching "Remove from Folder").
2. **Unsorted / last-membership orphaning.** Every chip (incl. Unsorted) showed a
   `×`, and `removeAssets` deletes unconditionally, so removing an item's last
   membership orphaned it (gone from every folder, still existing). Fix: a real
   collection is always removable — the store **re-homes to Unsorted** when the
   removal empties the membership set (mirroring move/ingest), so nothing orphans;
   only the Unsorted home is non-removable when it is the sole membership
   (`removable = id != unsortedID || collections.count > 1`). This keeps removal
   working for a single moved-into collection, which the earlier `count > 1` guard
   wrongly blocked.
3. **Add-chip padding.** The Collections "Add" `Menu` used
   `.menuStyle(.borderlessButton)`, whose chrome added an inset that misaligned it
   from the membership chips. Fix: `.menuStyle(.button).buttonStyle(.plain)` so the
   `DetailChip` alone defines the pill.

Known follow-up: the chip add/remove has no undo/toast (unlike `removeFromFolder`);
Space/search hosts don't wire `onMembershipChanged` (they show no folder grid to
stale). Both acceptable for now.

## Deferred

- **Bottom thumbnail filmstrip** (Figma) — its own task; needs neighbour
  thumbnail loading. `Theme.Colors.filmstrip` remains reserved.
- The ✦ Tags icon is a **manual** add affordance — there is no auto-tag/LLM
  service; one can be wired later behind the same trigger.

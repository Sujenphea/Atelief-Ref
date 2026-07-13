# 006 — Item Detail: Remaining Work (Tags Editor, Invocation, Kind Seam)

> Covers the "Item Detail" feature — which is **mostly already built** (landed
> uncommitted on main during this planning session): `ItemDetailView.swift` replaced the
> deleted `InspectorView.swift` as a full-window overlay. Spec:
> [022-item-detail-design](../022-item-detail-design.md), changelog `084`. This doc
> covers only what remains.

## Current state (as built)

- Full-window overlay inside the Library tab: big media area (image = full-res original
  decoded off-main with the 1280 preview as instant placeholder; video = inline AVKit
  `VideoPlayer`), `‹ prev / next ›` + counter stepping through the folder via
  `model.select(_:)`, Escape/Back to close, auto-dismiss on remove/delete.
- `DetailSidebar` (right, ~300pt): metadata (kind/dims/size/mime/date/duration),
  provenance (platform/author/title/URL), actions (Open Original Source, Open Full
  Resolution, Reveal in Finder, Copy Source Link, Remove from Folder, Delete) — ported
  from the old inspector.
- Invoked from grid cell tap (`LibraryView` `showDetail` local state).
- **Missing**: tags UI (services fully exist: `applyTag` / `removeTag` / `tags(for:)`,
  `AppServices.swift:596–658`, zero UI anywhere); canvas/keyboard invocation (canvas
  double-click only QuickLooks videos, `CanvasScreen.swift:50`); kind-extensible media
  area; zoom/pan.

## Options (for the remaining work)

### Presentation wiring
- **P1 — keep the lightbox overlay, drive it from `NavModel.presentedItemID`**
  (recommended): both the Collection grid and a Space canvas can open the same overlay;
  composes with [004](./004-navigation-redesign.md); the overlay suits `←/→`
  browse-the-set behaviour.
- **P2 — NavigationStack push route**: free back/title, but fights the lightbox
  prev/next feel. **Rejected.**

### Detail vs inspector
- **D1 — detail-only, componentized** (recommended, **settled by user**): extract
  `ItemMetadataView`, `ItemProvenanceView`, `ItemActionsView`, and a new `ItemTagsView`
  from `DetailSidebar`. The full detail page stays the single detail surface; a slim
  `.inspector()` can return later cheaply by composing compact variants of the same
  components.
- **D2 — reintroduce a slim inspector now**: a second surface to keep in sync before
  there's evidence browsing needs it. **Rejected for now.**

## Recommendation — P1 + D1, plus:

1. **Tags editor** (the substantive gap): `ItemTagsView` — tag chips with remove, an
   add field with autocomplete against the tag vocabulary. Model side:
   `@Published tags: [Tag]`, `loadTags(for:)` guarded by `selectedItemID` (the
   `loadPreview` race-guard pattern, `IngestionModel.swift:572`), `addTag(_:)` /
   `removeTag(_:)` → `applyTag`/`removeTag` with `TagSource.user`. Needs the
   `tagVocabulary(prefix:)` read from [007](./007-search-sort.md) — build once, share.
2. **Invocation**: grid double-click/Enter and canvas double-click (image tiles) set
   `NavModel.presentedItemID`; video double-click keeps QuickLook on canvas but plays
   inline in detail. Replace `LibraryView`'s local `showDetail` when 004-P1 lands.
3. **Kind seam for 003**: keep `mediaArea`'s per-kind `switch` shape so `.link` /
   `.color` / `.tweet` arms slot in without reshaping the view — coordinate with 003's
   `AssetContent` enum (switch on it, not on raw kind).
4. **View-count hook for 007**: detail-open is the one place a "view" is recorded — a
   single call site into 007's coalescer.
5. **Zoom/pan on images** (`MagnificationGesture` + drag): v1.5 — valuable but
   independent.

## Schema / migration impact

**None.** `tag`/`asset_tag` have existed since v1; services are complete and tested
(`ServicesTagsTests`). Note the model choice this UI exposes: tags are **asset-scoped
(global)** — tagging an item in one folder tags it everywhere it appears.

## Phased implementation

1. **F1 (S)** — extract the four `Item*View` components from `DetailSidebar`; wire
   `NavModel.presentedItemID` (with 004-P1; until then keep the local bool).
2. **F2 (S–M)** — tags editor: `ItemTagsView` + model tag state + pure tag-input helper
   (trim / normalize case / dedup / reject empty).
3. **F3 (S)** — canvas double-click + Enter invocation; `AssetContent` switch seam.
4. **F4 (S, optional)** — image zoom/pan.

## Test strategy

- Tag-input helper — pure unit tests (`GridReorder` pattern): trim, case-normalize,
  dedup, reject-empty, split-on-comma.
- Prev/next index math — extract from `ItemDetailView.swift:156–168` into a pure helper
  and test like `GridNavigation` (ends clamped, empty folder, item removed under you).
- Tag load race — guard-by-`selectedItemID` covered via the model test seam.
- Services already covered; views compile-only.

## Effort: **S–M**

## Risks & edge cases

- Tag commit/focus UX (Enter to commit, click-away behaviour) — easy to get subtly
  wrong; manual pass.
- Item removed while detail open is already handled (selectedItem nil-guard) — keep that
  property when moving to `NavModel.presentedItemID`.
- Prev/next after a tag edit must not reload/reorder `items` (tags don't affect the
  feed — assert in a test once 007's sort modes exist, since most-viewed *can* reorder).
- Detail over a **Space** context (from canvas): prev/next steps through what — the
  space's items? Define when 005-E2 lands (recommend: yes, space items in z/manual
  order).

## Settled decisions

- Full detail view is the single detail surface; componentize; no slim inspector now
  (user, 2026-07-13, superseding the earlier "inspector stays" answer after the
  mid-session discovery that it was already removed).

## Open questions

1. Confirm the asset-scoped (global) tag mental model is what you expect in the UI
   (tag once, tagged everywhere). Alternative — per-membership tags — would be a
   schema change and is NOT recommended.
2. Zoom/pan in v1 or v1.5? (Recommend v1.5.)

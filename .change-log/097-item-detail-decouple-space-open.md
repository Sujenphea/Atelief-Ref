# 097 — Item detail: decouple the view + open from the Space canvas

Completes F3's deferred canvas path ([023-item-detail-plan](../.docs/023-item-detail-plan.md),
F3b). `ItemDetailView` is now presentation-only, so the same page opens from the
collection grid **and** from a Space board's asset tile — the board had no path to
the detail page before.

## Summary

- **`ItemDetailView` is presentation-only**: it no longer observes
  `IngestionModel`. It takes an explicit `asset` + `source` + `blobURL` +
  `previewImage`, the `tags` + `onAddTag`/`onRemoveTag` closures, an
  `ItemDetailActions` bundle (each action optional — omitted ones disable or hide
  their button), and an **optional** `ItemDetailNavigator` for prev/next (absent
  when there's no ordered set). Media still decodes off-main on `asset.id` change.
  The sidebar sections take plain values (`MetadataSection(asset:)`,
  `ProvenanceSection(source:)`, `TagsSection(tags:…)`, `ActionsSection(actions:)`).
- **Grid** (`CollectionView.detailOverlay`): feeds the view from the folder's
  `IngestionModel` context — full actions + prev/next across `model.items`.
  Behaviour is unchanged from before the decouple.
- **Space** (`SpaceView`): double-clicking an **image asset** tile opens the
  detail page (video still → QuickLook; frame/text still → inspector; the
  image-asset case was previously a dead double-click). No prev/next (a board has
  no ordered set) and no folder remove/delete (the placement, not a membership, is
  the unit of removal — that stays the canvas tile's ⌫).
- **`AssetTagsStore`** (new): a small, selection-free tag store bound to one asset,
  so the Space overlay's tags editor works without `IngestionModel`'s
  folder-scoped selection. Same `AppServices` funnel; errors bridge to the shared
  app alert.
- **`IngestionModel`**: `blobURL(forAsset:)` + asset/source-based overloads
  (`openBlob(asset:)`, `revealInFinder(asset:)`, `openSourceURL(_:)`,
  `copySourceLink(url:)`); the existing detail-based methods now delegate to them
  (no duplicated `NSWorkspace`/`NSPasteboard` logic).

## Files changed

- `ItemDetailView.swift` — presentation-only rewrite; `ItemDetailActions` /
  `ItemDetailNavigator`; value-driven sidebar sections.
- `CollectionView.swift` — `detailOverlay(for:)` builder feeding the view.
- `SpaceView.swift` — asset-tile double-click opens the overlay; `AssetTagsStore`;
  tag-error bridge.
- `IngestionModel.swift` — `blobURL(forAsset:)` + asset/source action overloads.
- `AssetTagsStore.swift` — new.

## Migration notes

None — the grid detail page is behaviourally unchanged; the Space gains a new
open path. Public shape of `ItemDetailView` changed (now value-driven), but it has
exactly two call sites, both updated.

## Tests

App builds clean; `AtelierRefsTests` green. The tag CRUD is covered at the core
layer (`ServicesTagsTests`); the new wiring is SwiftUI presentation + gesture
plumbing over already-tested service methods.

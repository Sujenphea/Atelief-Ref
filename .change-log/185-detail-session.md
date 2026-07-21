# 185 — DetailSession: item-detail state off the god-object (036 §3 B1)

## Summary

Workstream B step B1 of `036-grid-smooth-plan.md` — fixes **root cause 3**
(item-detail churn) at its first source: the detail overlay's open/step state
rode `IngestionModel` as 3–4 separate `@Published` writes, so opening the page or
stepping prev/next re-ran **every** view observing the god-object — the whole
screen, grid included.

That state now lives in a dedicated `DetailSession` (one `@Published state`
struct) plus the existing `AssetTagsStore`, hosted in a new `CollectionDetailHost`
child view. `CollectionView` renders the host but does **not** observe it, so
opening and stepping publish only to the host — the grid never re-renders per
step.

### What moved off `IngestionModel`

Deleted: `openItem`, `loadPreview`, `previewImage` (`@Published`), `selectedTags`
(`@Published`), `loadTags`, `addTag`, `removeTag`, `reloadTagsIfCurrent`, and the
prune-time `previewImage/selectedTags` clearing.
Added: `previewImageURL(forAsset:)` (the large-tier placeholder URL — the only
surviving fragment of `loadPreview`, now consumed by `DetailSession`).
`recordView` stays on the model (open + step both record a view).

### Publish count — before vs after

| Action | Before (on `IngestionModel`, whole-screen fan-out) | After |
|---|---|---|
| **Open** | 4 model `@Published` writes (`previewImage=nil`, `selectedTags=[]`, async `previewImage`, async `selectedTags`) + 1 selection + 1 nav | **0** model detail-writes; 1 selection (lead) + 1 nav (route, pre-existing) + session/tags publishes reach only the host |
| **Step (prev/next)** | 1 selection + 4 model `@Published` writes → whole screen re-renders ~5× | **0** model / nav / selection writes; 1 `session.state` publish + tag rebind, **host-only** → grid body never runs |
| **Close** | flush + nav | flush + 1 selection (`.setLead` sync) + nav — unchanged in spirit |

### How the host avoids re-rendering the grid

`ObservableObject` `@StateObject`/`@ObservedObject` subscribes the **owner** to
`objectWillChange` regardless of body reads. So the session/tags stores live on
`CollectionDetailHost`, not `CollectionView` — a per-step publish invalidates only
the host. `CollectionView.body` reads neither `session.state` nor `tags.tags`, so
the grid config it builds is never rebuilt on a step.

## Files changed

- **`DetailSession.swift`** (new) — `@MainActor ObservableObject`, one
  `@Published private(set) var state: State?` (`detail` + `previewImage` +
  `displayImage` seam). `present`/`step` = one publish + async preview arrival;
  `dismiss`; `currentID`. Tags rebound via the injected `AssetTagsStore`.
- **`DetailSessionTests.swift`** (new) — 4 tests: `present()` is exactly one
  publish; `step()` leaves the model lead/selection untouched; close syncs the
  lead once; the `.setLead` reducer action (sets lead, keeps ids, returns
  `.scrollTo`, guarded no-op when unchanged).
- **`GridSelection.swift`** — new `.setLead(UUID)` action (sets the cursor, keeps
  the selection set, returns `.scrollTo`) for the lead-sync-on-close.
- **`CollectionView.swift`** — overlay gate → `CollectionDetailHost` (owns
  `DetailSession` + `AssetTagsStore`, raises off `NavModel.presentedItemID`,
  auto-dismisses on `contentsVersion` when the shown id vanishes, forwards tag
  errors to `model.lastError`); `detailOverlay(for:)` moved into the host;
  `open(_:)` drops `model.openItem` for `applySelection(.setLead)` + present-via-route.
- **`IngestionModel.swift`** — deletions above + `previewImageURL(forAsset:)`.

## Parity notes

- **Auto-dismiss on delete:** was the `leadItem == nil` gate collapsing when the
  reload pruned the lead. Now the host watches `contentsVersion` and closes if
  `session.currentID` is no longer in `model.items` — same outcome, keyed to the
  **stepped** item (more correct: prev/next no longer moved the model lead). Like
  today, this path does not flush view bumps (the debounce timer / next close
  does).
- **Tags:** routed through `AssetTagsStore` (same store the Space board + search
  overlays use); no non-detail caller of the deleted model tag methods existed
  (grep-verified), so nothing needed repointing. Tag errors surface on
  `model.lastError` exactly as before.
- **Lead-on-close:** prev/next now keep the lead off the model; on close the lead
  is synced once via `applySelection(.setLead(currentID))`. The returned
  `.scrollTo` effect is **discarded** — the grid did not scroll on close before B1
  either (the store publish only reconciles the lead ring), and there is no scroll
  seam from this parent. End state (lead on the last-viewed item, ring reconciled,
  no scroll) is identical to before.
- Escape-to-close (`.cancelAction` Back), spacebar QuickLook, and open/close fade
  are unchanged.

## What's left for B2–B4

- **B2** (`DetailImageLoader` + LRU / neighbor preload) — `State.displayImage` is
  the seam (present in B1, always `nil`; `ItemDetailView` still decodes its own
  full-res off `blobURL`).
- **B3** decode strategy (bucketed downsample / zoom-native) — unchanged, still in
  `ItemDetailView.loadMedia`.
- **B4** coalesced open + non-disruptive Most-Viewed reorder — `flushViewBumps`
  still triggers a full `loadContents` on close in `.mostViewed`; B1 deliberately
  did not touch it (it would pull B4 forward). The "set lead on open, never on
  step" invariant B4 relies on is already satisfied here.

## Amend to `036`

The plan's B1 text says "`CollectionView` holds the session as `@StateObject`."
That doesn't survive SwiftUI's `ObservableObject` invalidation semantics — the
owner is subscribed regardless of body reads, so the session must live on the
**child** (`CollectionDetailHost`). Implemented that way; noted in the host's doc
comment.

## Migration notes

No data or schema changes. `IngestionModel.previewImage`/`selectedTags` and the
tag mutators are gone — any future detail surface should use `DetailSession` +
`AssetTagsStore` (the established pattern), not the god-object.

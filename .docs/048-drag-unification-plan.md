# 048 — Drag System Unification Plan

## Goal

Reduce the app's four drag-and-drop harnesses to a coherent set of **two shared
cores with thin, necessary presentation shells**, and eliminate the search-grid
drag lag as a *structural* side effect (not a patch).

## Current state

Four host harnesses over two already-shared "brains":

| Axis | AppKit host | SwiftUI host | Shared brain |
|------|-------------|--------------|--------------|
| **Asset drag** | `MasonryGridHost` (via `CollectionView`) — fast | `LibrarySearchResults` (`LibrarySearch.swift`) — **laggy** | `GridSelection` reducer + `AssetDragPayload` |
| **Collection drag** | `CollectionsOutlineView` (sidebar tree) | `CollectionsGalleryView` (home cards) | `CollectionTargets` + `CollectionDragPayload` |

The payloads (`AssetDragPayload`, `CollectionDragPayload`) are byte-compatible
across AppKit/SwiftUI, and the routing/selection brains are already shared. The
duplication that remains is in the **host harnesses**, split along AppKit vs
SwiftUI.

## Decisions (confirmed)

1. **Asset drag → fold search into `MasonryGridHost`.** Search stops
   reimplementing the grid in SwiftUI and renders through the same AppKit grid
   as `CollectionView`. One asset-drag system; native `NSDraggingSession`; the
   lag root cause disappears.
2. **Search layout → masonry.** Search results adopt the masonry layout (not the
   current uniform fixed-column `LazyVGrid`), so no layout shim is needed.
3. **Card select → adopt the `GridSelection` reducer** in
   `CollectionsGalleryView`, replacing the plain `Set<UUID>` marquee-only state,
   so home cards gain cmd/shift-click and behave identically to the asset grid.
4. **Collection drag → leave as-is.** The sidebar tree and home cards are
   different frameworks *and* different drop semantics (tree = reorder+nest,
   cards = nest-only), already unified at the brain (`CollectionTargets`). No
   host merge — it would regress one presentation for zero shared-logic gain.

## Root cause of the search lag (for the record)

Verified in `LibrarySearch.swift`:

1. **Grid rebuilds continuously during drag (primary).** Each cell writes its
   frame into parent `@State` via `.onGeometryChange { cardFrames[id] = $0 }`
   (`:599-601`). Mutating `cardFrames` invalidates `LibrarySearchResults.body`,
   rebuilding every `resultCell`. During a drag the `LazyVGrid` reflows/auto-
   scrolls, firing this repeatedly. `hoveredID` (`:588-591`) does the same.
2. **Full-size synchronous drag preview.** `.draggable(dragPayload(for: id))`
   (`:597`) has no `dragPreview:`, so SwiftUI rasterizes the live 384-bucket
   cell on the main thread at drag start. The AppKit grid precomputes an 84pt /
   192-bucket image once (`CollectionView.swift:582-589`).
3. **Non-`Equatable` `AssetDetail`** (`:98-100`) means SwiftUI can't cheaply skip
   unchanged cells when the parent body invalidates.

Folding search into `MasonryGridHost` removes #1 and #2 entirely (no SwiftUI view
tree churns during a native drag; the drag image is the precomputed small one)
and makes #3 irrelevant.

## Work item A — Fold search into `MasonryGridHost`

**Outcome:** `LibrarySearchResults` renders its results through `MasonryGridHost`
using a `GridHostConfiguration`, mirroring `CollectionView.appKitGrid(geo:)`
(`CollectionView.swift:498-538`).

**Steps**
1. Build a `GridHostConfiguration` in the search results view fed by
   `search.results` as the items source (map `AssetDetail` → the item shape the
   host expects), with `search.selectionStore` as the selection store.
2. Configure for search semantics:
   - `canReorder: false` (search results have no manual order).
   - Copy-only drop-out: reuse the sentinel `AssetDragPayload.nilSourceID`
     source id so every external drop is a **copy/add**, never a move — matches
     the current `dragPayload(for:)` behaviour (`LibrarySearch.swift:675-679`).
   - Provide `dragImage:` via the same small `ImageRenderer` path
     (`CollectionView.swift:521-526`) so the drag preview is the precomputed 84pt
     image.
3. Wire selection through the existing `GridSelection` reducer (already used by
   search via `gridClickAction`/`apply`) — now owned by the host, so the
   `.simultaneousGesture` cmd/shift wiring (`LibrarySearch.swift:571-576`) and the
   `marqueeCatcher` (`:609+`) are **deleted** from the SwiftUI layer.
4. Delete the SwiftUI drag/marquee/frame-tracking scaffolding:
   `cardFrames`, `hoveredID`, `.onGeometryChange`, `.draggable`, the marquee
   gesture, and `resultCell`'s hand-rolled selection overlays.

**Files**
- `AtelierRefs/AtelierRefs/LibrarySearch.swift` (main change; large deletion in
  `LibrarySearchResults`)
- `AtelierRefs/AtelierRefs/MasonryGridHost.swift` /
  `CollectionView.swift` (reference the existing config; extend
  `GridHostConfiguration` only if search needs a knob the grid doesn't expose)

**Open question / gate**
- Confirm `MasonryGridHost` renders search-quality thumbnails at the search
  density. If search wants a slightly different cell size, drive it through the
  existing `density`/`spacing` config rather than a new layout path.

**Risks**
- Feeding a *non-collection* items source (membership-less search hits) into a
  host that assumes collection items — verify `onReorderCommit`, `actionTargets`,
  and delete/move closures degrade gracefully (copy-only, no reorder, no
  remove-from-collection).

## Work item B — Adopt `GridSelection` in `CollectionsGalleryView`

**Outcome:** Home collection cards gain cmd-click (toggle) and shift-click
(range) and behave identically to the asset grid; marquee still works.

**Steps**
1. Replace `@State private var selectedCardIDs: Set<UUID>`
   (`CollectionsGalleryView.swift:33`) with a `GridSelection` value + a small
   store (mirror `GridSelectionStore`), keyed by collection `UUID`.
2. Route card clicks through `gridClickAction(imageID:shift:command:)` +
   `apply(...)`, using `.simultaneousGesture(TapGesture().modifiers(.command))`
   and `.modifiers(.shift)` — the pattern from `LibrarySearch.swift:571-576`.
   Gate the plain-click "open collection" when modifiers are held (mirror
   `LibrarySearch.swift:556-558`).
3. Feed the card order (`selectableIDs`, ~`:298-303`) as the reducer's `order:`
   so shift-range slices contiguously; keep Unsorted excluded.
4. Point the existing marquee (`updateMarqueeSelection()`, ~`:305-313`) and the
   batch-delete bar at the new selection value.

**Files**
- `AtelierRefs/AtelierRefs/CollectionsGalleryView.swift`
- Reuse `GridSelection.swift` / `GridSelectionStore.swift` as-is.

**Risk / gotcha**
- SwiftUI `Button` doesn't fire on a modified click — hence the
  `.simultaneousGesture(TapGesture().modifiers(...))` pattern is mandatory, not
  the button action. The fanned/rotated card transform doesn't affect per-card
  hit-testing.

## Work item C — Collection drag (no change)

Documented decision: leave `CollectionsOutlineView` (tree) and
`CollectionsGalleryView` drag *host* separate. They already share
`CollectionTargets` (routing) and `CollectionDragPayload` (bytes). A host merge
would rebuild one presentation in the other's framework and lose either the
tree's reorder/disclosure or the cards' fan/marquee, for no shared-logic gain.

## Suggested sequencing

1. **A first** — biggest win (one asset system + lag fix), and it validates the
   `MasonryGridHost` config surface for a non-collection source.
2. **B second** — independent, smaller, uses machinery A leans on.
3. C is a no-op (this doc records the decision).

## Migration notes

- No payload/pasteboard format changes — `AssetDragPayload` and
  `CollectionDragPayload` bytes are unchanged, so drop targets (sidebar, spaces,
  Finder promises) keep working.
- Net code deletion expected in `LibrarySearch.swift` (the hand-rolled SwiftUI
  drag/marquee/selection scaffolding is replaced by host config).
- Add a `.change-log/` entry per work item on completion.

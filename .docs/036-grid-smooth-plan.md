# 036 — Collection grid smoothness: plan

Implementation plan for making the collection grid smooth end-to-end (scroll,
multi-select, detail open/step/close) at 500–2000 items. Companion to
`035-grid-scroll-perf-research.md`, which measured the scroll residual and
sketched the forward options; this plan takes **Option B** (AppKit
`NSCollectionView`) plus the selection split, the detail-view fixes, and the
thumbnail pipeline work that 035 §7 deferred.

> **AMENDED after measurement — read `038-grid-bakeoff-results.md` first.**
> A three-way bake-off at 200 and 2000 items (protocol in `037`) changed three
> things in this plan:
> 1. **035's Option A (equatable cell) is refuted** — measured no better than
>    the current grid and often worse. It is removed from consideration; do not
>    revive it.
> 2. **Workstream A1–A4 is NOT yet justified.** The bake-off cannot separate
>    `NSCollectionView` recycling from the bucketed-`CGImage` thumbnail
>    pipeline that the AppKit mode necessarily bundled. Workstream C now runs
>    **first**, followed by a re-measurement that decides A1–A4. See §5.
> 3. Two "AppKit wins" are not framework properties at all and are pulled
>    forward into the SwiftUI path — see §4.5.

## 1. Root causes (investigated, corroborated by 035)

1. **Band-boundary re-materialization.** Every band crossing rebuilds ~100
   cell wrappers (`.draggable`/`.dropDestination`/`.contextMenu`/`.onHover`
   trees) when only ~8–12 cells enter/leave — `.equatable()` guards only the
   inner `CollectionCell` (`CollectionView.swift:561`), not the `masonryCell`
   wrapper (`:531–581`). Measured ~1.6s/20s main-thread work (035 §4).
2. **Selection rides the god-object.** `selection` is `@Published` on
   `IngestionModel` (`IngestionModel.swift:83`); every click, shift-click,
   arrow key, and marquee tick whose hits changed re-executes the entire
   `CollectionView` body. The grid-global `isSelecting` flag additionally
   invalidates + animates every visible cell on first-select/last-deselect.
   (Marquee *geometry* was correctly isolated in `GridMarqueeState`; selection
   never got the same treatment.)
3. **Item detail churn.** Detail is an overlay over the still-mounted grid;
   opening fires 3–4 separate `@Published` writes (`lead`, `previewImage`,
   `selectedTags`); full-res is decoded uncached on every prev/next
   (`ItemDetailView.swift:264–289`); Most-Viewed sort triggers a full
   `loadContents` reload on close (`IngestionModel.swift:1074–1089`).
4. **Thumbnail pipeline breaks past ~512 items.** `ThumbnailCache` NSCache is
   count-limited to 512 with no byte cost (`SharedThumbnail.swift:24`) —
   thrashes at target scale; 512px JPEGs decoded full-size for ~150px cells;
   `NSImage(data:)` defers pixel decode to first main-thread draw; no prefetch
   beyond the windowing overscan.

**Decisions:** full NSCollectionView rewrite (035 Option B) over the cheap
equatable-wrapper fix; selection split off `IngestionModel`; detail fixed
broadly (open + step + close); thumbnail work in scope (real collections are
500–2000 items).

**Keep (framework-independent, unit-tested):** `GridSelection` reducer,
`MasonryLayout` analytic frames, `MasonryLayoutCache`, `MarqueeMath`,
`GridNavigation`, `gridPressRouting`/`gridClickAction`.

---

## 2. Workstream A — NSCollectionView grid migration

**Load-bearing fact:** `MasonryLayout.layout` produces index-aligned `[CGRect]`
in top-left-origin content space (incl. `topInset`), and `NSCollectionView` is
a flipped view — the frames map 1:1 with zero conversion.

> **Verified, with a sub-pixel asterisk (038 §3.4).** The coordinate space is
> confirmed: layout *attributes* carry the analytic frames byte-for-byte. But
> AppKit **pixel-snaps the item views** it places from those attributes, and
> masonry heights are `columnWidth / aspect` — routinely fractional. Worst
> measured deviation 0.233 pt over 612 comparisons (bounded by half a backing
> pixel; the snap rule is NOT `backingAlignedRect(.alignAllEdgesNearest)` —
> 6 of 12 cells disagreed, so only the bound is safe to rely on).
> **Consequence:** hover, marquee, selection rings and hit-testing must ride the
> **analytic** frames, never `cell.view.frame`. Read literally, "zero
> conversion" invites exactly the opposite and would drift sub-pixel against
> what is drawn.
`masonryMarqueeIndices` (`MarqueeMath.swift:77`) is exactly the rect query
`layoutAttributesForElements(in:)` needs.

**Precondition:** merge `6933a17` (skeleton-on-switch, `loadedCollectionID` +
`isLoaded` gate) into this branch — A1 builds on that gate.

### A0. Selection extraction (shippable alone; do first)

New `AtelierRefs/GridSelectionStore.swift` — `@MainActor ObservableObject` with
`@Published private(set) var selection = GridSelection()`, injected `order`,
`apply(_:columns:) -> GridSelectionEffect`, `setLead`, `replace` (Jump).

- `IngestionModel`: delete `@Published var selection`; keep
  `let selectionStore` + computed `var selection` for internal readers
  (`leadItem`, `selectedAssetIDs`, `dragPayload`, `actionTargets`).
  `rebuildItemDerivations()` calls `setOrder`; `loadContents` prunes via the
  store; `selectedAssetIDs` rebuilt from a Combine sink on `$selection`
  (replaces the `didSet`). `applySelection` forwards to the store (single
  seam, no call-site churn).
- Immediately kills "every selection publish re-runs the whole screen" even
  before the AppKit grid lands; the coordinator subscribes to this store later.

> **CORRECTED after A0 (`38dff33`).** Two adjustments to the above:
> - **Scope of the win is narrower than "re-runs the whole screen."** A0 stops
>   selection publishes invalidating *every other view observing `IngestionModel`*
>   (the god-object fan-out). It does **not** stop `CollectionView`'s own body
>   re-running — its ~nine body-level `selection` reads remain until A1–A2 push
>   them into per-cell views.
> - **A0 is not purely an `IngestionModel` change.** Once `model.selection` stops
>   being `@Published`, reading it in a SwiftUI body no longer subscribes — so
>   `CollectionView` had to gain an explicit `@ObservedObject` on the store (plus
>   a custom init) or selection changes wouldn't repaint at all. That subscription
>   *is* the mechanism delivering the narrower fan-out win. While the grid is
>   still SwiftUI, the store must be observed by whoever renders selection; the
>   AppKit coordinator replaces that observer later, it doesn't add the first one.

### A1. AppKit grid renders read-only behind a flag

- New `AtelierRefs/MasonryGridHost.swift` — `NSViewRepresentable`:
  `NSScrollView` → `MasonryNSCollectionView` subclass,
  `isSelectable = false` (native selection bypassed entirely — the
  `GridSelection` reducer stays the only truth), clear backgrounds.
  `GridHostConfiguration` value struct (items, itemsVersion, columns,
  spacing/topInset, closure bundle held by the Coordinator). `updateNSView`
  diffs `(itemsVersion, columns)`; width changes observed by the layout itself.
- New `AtelierRefs/MasonryCollectionLayout.swift` — `NSCollectionViewLayout`
  wrapping `MasonryLayoutCache` verbatim; `layoutAttributesForElements(in:)` =
  `masonryMarqueeIndices` over the rect (native windowing/recycling for free —
  `GridWindow` banding becomes obsolete);
  `shouldInvalidateLayout(forBoundsChange:)` compares **width only** (scrolling
  must not invalidate); attributes cached per index.
- Data: `NSCollectionViewDiffableDataSource<Int, UUID>` (id = membership
  `item.id`). Wholesale `items` republish → snapshot apply with
  `animatingDifferences: false`; same-id content edits → `reconfigureItems`
  (never `reloadItems` — reload flashes). Coordinator keeps `idToIndex`.
- Cell strategy — **hybrid, mostly native**: new
  `AtelierRefs/MasonryGridItem.swift` (`NSCollectionViewItem`) with a
  layer-backed view: `layer.contents` + `.resizeAspectFill` + cornerRadius for
  the image (crop-fill), selection/cursor ring sublayers, circle `NSButton`
  (alpha-animated 0.12s), lazy `NSHostingView` **only** for media-less
  link/tweet card tiles (`sizingOptions = []`, rootView updated on reuse,
  never recreated), lazy GIF overlay. Rationale: per-cell `NSHostingView`
  layout cost was the original measured bottleneck (035 §1); the dominant cell
  kind is just "image + border". `configure` = sync cache hit → async load
  with identity re-check; `prepareForReuse` cancels tasks/dwell, releases the
  GIF slot. `applySelectionState(CellSelectionState)` mutates layers only —
  the targeted-invalidation entry point. Accessibility label logic moves to a
  shared pure function.
- Prefetch: coordinator adopts `NSCollectionViewPrefetching` →
  `ThumbnailPipeline.prefetch/cancelPrefetch` (Workstream C; cells use the
  pipeline with buckets, not the old `ThumbnailCache`).
- Skeleton/empty/stale stay SwiftUI: `if isLoaded { MasonryGridHost(...) }
  else { skeleton }`; reset offset on collection change.
- Feature flag `AtelierUseAppKitGrid` (UserDefaults + debug toggle);
  `CollectionView.grid` branches AppKit host vs existing `masonryWindow`.
  Everything outside `grid` (header, toolbar, drop rail, stack row, chips,
  detail overlay, pane-level `.onDrop`) untouched.
- Exit: renders + scrolls with no `layoutAttributesForElements` hotspots,
  prefetch warms, switch shows skeleton, empty state OK.

> **As built in A1 (`761f106`) — three deviations from the text above:**
> 1. **`reconfigureItems` does not exist on `NSCollectionViewDiffableDataSource`
>    in this SDK.** Same-id content edits instead re-run `configure` on the
>    materialized cells directly (no snapshot, never `reloadItems`); offscreen
>    cells reconfigure via the item provider on scroll-in. Same intended effect
>    (no flash, no relayout). Wherever this plan says `reconfigureItems`, read
>    "re-run `configure` on materialized cells."
> 2. **Config diffs `(itemsVersion, density)`, not `(itemsVersion, columns)`.**
>    Columns are width-derived, so density is the stable input; the layout
>    derives columns from the live clip width (matching the SwiftUI path), and
>    width-crossing column changes go through the clip-view width observer.
> 3. **Media-less hosting is slightly broader than "link/tweet only"** — the
>    hosted `AssetContentThumbnail` also covers colour/unknown kinds, reusing the
>    one existing render seam. Image/video remain pure-layer as specified.
>
> Also: `applySelectionState`, the ring layers, and the circle button are
> present but **inert** in A1 — A2 wires them. Scroll-invalidation is avoided by
> width-only `shouldInvalidateLayout` + a per-index attribute cache built in
> `prepare()`, so a scroll query only selects cached attributes and allocates
> nothing. `analyticFrame(at:)` is exposed on the layout for A2/A3 hit-testing
> (per the 038 §3.4 pixel-snap asterisk — ride analytic frames, never live).

### A2. Selection, mouse, hover, keyboard, scrollTo, density

- Coordinator subscribes `selectionStore.$selection`; new pure
  `selectionCellDelta(from:to:) -> (changed: Set<UUID>, modeFlipped: Bool)`
  (symmetric difference ∪ lead moves). `reconcileSelection` touches only
  changed visible items via `applySelectionState` (mode flip → all visible).
  **No snapshot, no relayout** — pure layer mutation. This is what makes
  multi-select smooth.
- Mouse: cell view overrides `mouseDown` — circle hit → `.tapCircle`; else
  modifiers → the existing tested `gridPressRouting`/`gridClickAction` tables;
  local drag-threshold loop (~4pt) decides click vs drag hand-off. The SwiftUI
  delivery hacks (`PressReportingButtonStyle`, dual `simultaneousGesture`) die;
  the pure routing tables survive.
- Hover: one tracking area on the collection view; `mouseMoved` + clip-view
  `boundsDidChangeNotification` re-hit via zero-rect `masonryMarqueeIndices` —
  structurally fixes hover-during-scroll and the stranded-circle case
  (`hoverAfterWindowChange` dies).
- Keyboard: collection view becomes first responder on click; `keyDown` for
  arrows/return/esc/space/x, `performKeyEquivalent` for ⌘A/⌘±, responder-chain
  `deleteBackward/Forward` replaces `.onDeleteCommand`. Remove the SwiftUI
  `.focusable()/.onKeyPress` chain when the flag is on. Escape falls through
  to `super` when not selecting (overlay close still works).
- `scrollTo` → `animator().scrollToItems(at:scrollPosition:)`. Density change:
  record topmost visible index before invalidation, restore after
  (non-animated first; animated polish deferred).
- Exit: full parity for click/⇧/⌘, circle, arrows,
  return/esc/space/x/⌘A/⌘±/delete; Instruments confirms a selection change
  touches only affected items.

> **As built in A2 (`b276bf1`) — notes and one honest gap:**
> - **Whole-body-republish elimination is partial, by design at this step.**
>   The coordinator's *cell* reaction is fully layer-only (only changed∩visible
>   cells repaint; proven by `selectionReconcileTargets` tests). But
>   `CollectionView` still observes `selectionStore` at the struct level (A0's
>   subscription, which A2 was told not to touch), so its *body* still
>   re-evaluates on selection. On the AppKit path that body renders **no cells**,
>   so there is no per-cell work and no relayout — the cost is a near-empty body
>   pass. Fully removing even that needs the A0-flagged refactor (move the nine
>   body-level `selection` reads down into per-cell views). Tracked, not done.
> - **Reconcile split into two pure functions:** `selectionCellDelta(from:to:)`
>   and `selectionReconcileTargets(delta:visibleIDs:)` (the plan named one
>   `reconcileSelection`). Off-screen changes and a non-visible lead are excluded
>   from the live touch and repaint from `configure` on scroll-in.
> - **Circle hits go through the `NSButton` hit area**, not a `mouseDown` rect
>   test. **Delete** is routed both via the key predicate and the responder
>   `deleteBackward/Forward` methods. **Escape** consumes only while selecting.
> - **Deferred to A3 (bundled with the marquee, noted here so it isn't lost):**
>   empty-background **click-to-clear** selection. It rides the same
>   marquee/background mouse handling A3 builds, so it was not wired in A2.

### A3. Drag out, drop, context menu, marquee, GIF

- Drag out: `NSDraggingSource` from the threshold loop; pasteboard =
  JSON-encoded `AssetDragPayload` under `com.ref-atelier.asset-ids` —
  **byte-compatible with SwiftUI `Transferable.CodableRepresentation`** so the
  still-SwiftUI drop rail/stack row/Spaces keep accepting it (round-trip test
  in `AssetDragPayloadTests`). Drag image via `ImageRenderer` over the
  existing `dragPreview`.
- Drop onto cell: register **only** the asset-ids UTI so external
  file/image drags fall through to the pane-level SwiftUI `.onDrop`
  (`CollectionView.swift:209`) — verify fall-through early; fallback =
  register + forward. `validateDrop` forces `.on`; `acceptDrop` → existing
  `handleCellDrop`/`routeDrop`.
- Context menu: `menu(for:)` on the collection view builds `NSMenu` lazily
  (Move/Add submenus from the memoized `MoveTargetsCache`, Set as Cover,
  Remove, Delete). Also removes the eager per-cell `.contextMenu` cost.
- Marquee: new `AtelierRefs/GridMarqueeController.swift` (AppKit). Keeps
  `marqueeRect` + `masonryMarqueeIndices` + reducer `.marquee(hits:base:)`;
  only event/drawing moves: `mouseDown` on empty space, `mouseDragged` →
  targeted invalidation per tick, rectangle = one `CALayer` with
  `CATransaction` (no view rebuilds), auto-scroll reuses the proven
  `DisplayLinkPump` (velocity ramp intact). Native rubber band stays off.
- GIF hover: dwell task + `GifAnimationCoordinator.claim/release` ported into
  `MasonryGridItem` (reduce-motion via
  `NSWorkspace.accessibilityDisplayShouldReduceMotion`); pure policy fns
  (`shouldAnimateGif`, `gifWithinBudget`) reused as-is.

### A4. Flip default, delete old path

- Soak with the flag on (marquee+autoscroll at edges, 2000 items, drag to
  rail/stack/spaces, external drop, QuickLook, Jump, undo toasts).
- Delete: `masonryWindow`/`masonryCell`/`selectionCircle`, the key-press
  chain, `GridWindowing.swift` (all of it if the layout calls
  `masonryMarqueeIndices` directly), `MarqueeCaptureLayer`/
  `MarqueeRectangleLayer`/`DisplayLinkHost`/`GridMarqueeState` (keep
  `DisplayLinkPump`), `PressReportingButtonStyle` + gesture hacks. Keep
  `AssetContentThumbnail` (used by drag preview / search / add-from-library).
  Deletion = one isolated commit; flag removed one release later (rollback =
  flip flag, then revert commit).

### A. Risks & mitigations

- **Coordinate conversions**: one helper `contentPoint(for: NSEvent)` used by
  click/hover/marquee/menu; manual clicks inside `topInset` and past content
  bottom.
- **First-responder fights**: Escape falls through when not selecting; card
  hosting views non-interactive; search field focus verified.
- **NSHostingView reuse/leaks**: `sizingOptions = []`, update rootView only,
  leak-check after a 2k-item soak.
- **Invalidation storms**: assert via Instruments that scrolling produces zero
  `prepare()` calls.
- **Drag payload compatibility**: round-trip test; if encodings ever diverge,
  write both representations on the pasteboard item.

---

## 3. Workstream B — Item detail smoothness

### B1. New `DetailSession` observable (new: `AtelierRefs/DetailSession.swift`)

Move all detail-open state off `IngestionModel` into one small object with a
**single `@Published private(set) var state: State?`** struct
(detail + previewImage + displayImage), so `present()` is ONE publish and
async image arrivals publish only to the overlay.

- Tags via the existing `AssetTagsStore` (already used by Space board + search
  overlays): `present()/step()` call `tags.bind(to: asset.id)`. Delete
  `IngestionModel.selectedTags`, `loadTags`, `addTag`, `removeTag`,
  `reloadTagsIfCurrent` (`IngestionModel.swift:1193–1242`).
- **Prev/next must not touch `IngestionModel`**: `step(to:)` mutates only
  `DetailSession.state`; sync the lead back once on close via
  `model.applySelection(.setLead(currentID))` (add `.setLead` to the reducer)
  + `scrollTo`.
- Extract `CollectionDetailHost` child view: `CollectionView` holds the
  session as `@StateObject` but never reads `state` in its own body →
  per-step publishes re-render only the host, not the grid.
- Call sites: overlay gate (`CollectionView.swift:79–97`), `open(_:)`
  (`:697–701` — drop `model.openItem`), `detailOverlay(for:)` (`:655–690` →
  moves into the host). Delete `openItem`/`loadPreview`/`previewImage` from
  `IngestionModel` (`:1148–1172`). Auto-dismiss on delete: host observes
  `itemsVersion` and closes if the current id vanished.

### B2. Full-res LRU + neighbor preload (new: `AtelierRefs/DetailImageLoader.swift`)

- `DetailImageCache`: `NSCache`, key `"hash#bucket"`,
  `totalCostLimit ≈ 384 MB`, `countLimit = 5`, cost = decoded byte size.
- `actor DetailImageLoader`: `displayImage(hash:url:targetLongSidePx:)`,
  `preload(...)` at `.utility`, `retainOnly(hashes:)` cancels in-flight
  preloads outside {prev, current, next}. In-flight `[key: Task]` map
  coalesces duplicates; promoted preloads are awaited, not re-decoded.
- Preload prev/next only after the current item's image resolves. Pure
  `detailNeighbors(items:currentID:)` helper (unit-testable).

### B3. Decode strategy

`ItemDetailView` has zoom (up to 6×, `ZoomableImage`,
`ItemDetailView.swift:452–509`):

1. Media-area long side ≤ 1280px → the existing 1280-tier preview IS the
   display image (no blob decode; common laptop case). Measure via
   `onGeometryChange`, pass `targetLongSidePx`.
2. Larger viewports → downsampled decode via
   `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceThumbnailMaxPixelSize`)
   through the shared `ImageDecode` helper (fully-decoded bitmap — no lazy
   main-thread decode; never materializes a 40MP pano at 2400px).
3. Zoom > 1 → request native-size decode through the same loader; swap when it
   lands (downsampled image stays up meanwhile). Neighbor preloads use the FIT
   bucket only. Quantize `targetLongSidePx` to buckets (1280/2048/3072/native).

### B4. Coalesced open + non-disruptive Most-Viewed reorder

- After B1, an open = one `NavModel.presentedItemID` publish + one optional
  `selection` (lead) publish. Set the lead on open only, never on step.
- `flushViewBumps` (`IngestionModel.swift:1074–1089`): when detail is
  presented (plain non-published `isDetailPresented` flag), record views but
  defer the reorder; on close use `withAnimation(...) completion:` so it lands
  after the fade.
- Replace the full `loadContents` reload with a **local pure reorder** (new
  `MostViewedReorder.swift`): bump local `viewCount`s and stable-sort with
  core's exact tiebreak (`view_count DESC, created_at DESC, id DESC`,
  `Enums.swift:75`); skip the publish when order is unchanged. Extend
  `ViewBumpCoalescer.drain()` to return per-id counts (has tests). Full
  `loadContents` remains only as fallback on `recordViews` error.

---

## 4. Workstream C — Thumbnail pipeline for 500–2000 items

### C1. Decode helper + `ThumbnailPipeline.swift`

Replaces `ThumbnailCache` (`SharedThumbnail.swift:20–36`).

**Reuse, don't duplicate:** the 012 line already landed
`AtelierIngestion/Sources/AtelierIngestion/Imaging/ImageDecoding.swift` —
`thumbnailCGImage(from:maxPixelSize:)`, the same
`CGImageSourceCreateThumbnailAtIndex` dance (always-synthesize +
EXIF-transform), already shared by `ThumbnailGenerator`, `PerceptualHash`, and
`ColorExtractor`. The app target imports `AtelierIngestion` already, but the
enum is **internal**, so step one is marking `ImageDecoding` and its method
`public` rather than writing a second decoder in `AtelierRefs`.

Two gaps to close on top of it:
- It takes `Data`, not a `URL` — add a URL overload there (or read bytes
  app-side) so the grid path doesn't hold whole files in memory needlessly.
- It returns a bare `CGImage` with no byte cost — the pipeline needs
  `bytesPerRow * height` for the cache's `totalCostLimit` accounting, and
  should set `kCGImageSourceShouldCacheImmediately` so no lazy decode lands on
  the main thread at first draw.

  **CORRECTED after C1 (`307622d`).** The eager decode is *not* caused by
  `kCGImageSourceShouldCacheImmediately`. Measured with the flag on and off
  across two buckets, build and first-draw times were identical to within
  noise: on the `CGImageSourceCreateThumbnailAtIndex` path the flag is a
  **no-op**, because thumbnail synthesis already returns a rasterized bitmap.
  The actual win is `CreateThumbnailAtIndex` + bucketing versus `NSImage`'s
  lazy provider — 1.07 ms first draw **on main** for `NSImage(data:)` against
  0.12–0.30 ms for the pipeline, medians of 20 over the real 512 px tier file.
  The flag is kept (it states the requirement, and becomes load-bearing for any
  future full-size `CreateImageAtIndex` decode) but it is not the mechanism.
  The same misattribution appears in the `AppKitBakeoffGrid` comment — so the
  AppKit mode's advantage was never attributable to it either.

Workstream B (`DetailImageLoader`) uses the same helper.
- Pure bucket ladder `thumbnailPixelBucket(pointLongSide:scale:)` → snapped UP
  to {128, 192, 256, 384, 512}; 512 = tier ceiling.
- `ThumbnailPipeline` (singleton):
  - `cached(hash:bucket:)` — sync hit; falls back to nearest (prefer larger)
    cached bucket for instant paint.
  - `image(hash:url:bucket:) async` — `.userInitiated`, coalesced via
    `[ThumbnailKey: Task]`.
  - `prefetch([...])` / `cancelPrefetch(hashes:)` — `.utility` behind a
    max-4-concurrent gate; visible requests bypass and promote.

    **As built (C1/C3), two properties worth stating explicitly:**
    - `cancelPrefetch` **cannot interrupt a decode already in progress** —
      cancellation is checked once, before entering the decode closure. This is
      the right design (a half-decoded `CGImage` is worth nothing), but it makes
      any test asserting "cancelled ⇒ not cached" **racy**; assert only the
      deterministic half.
    - A visible request **joins** an in-flight prefetch rather than starting a
      second decode. Consequence: a hash crossing from the prefetch ring into
      the visible window must be **excluded from cancellation**, or the next
      band change cancels the very decode the on-screen cell is awaiting and
      blanks it. Guarded in two places (`masonryPrefetchIndices` excludes the
      rendered set; `update(requests:keep:)` takes the rendered hashes), both
      tested. Any future prefetch caller must preserve this.
  - Cache: `NSCache` keyed `"hash#bucket"`,
    `totalCostLimit = clamp(physicalMemory/16, 128 MB...512 MB)`, cost =
    decoded bytes, no countLimit. API is hash+url+bucket only (no SwiftUI
    types) so both the SwiftUI path and NSCollectionView prefetching use it.

### C4 (new). Container-level lazy context menu

Pulled out of A3 into the SwiftUI path, because it is **not an AppKit
advantage** — it is a design change A3 happened to bundle. A3 already notes
`menu(for:)` "removes the eager per-cell `.contextMenu` cost"; that cost can be
removed without the migration.

Today every visible cell eagerly builds a complete `NSMenu`-equivalent tree —
two `Menu`s each looping every destination, plus buttons and a divider — during
scroll, for a right-click that will land on at most one cell. 035 §4 measured
122 ms/20 s (326 ms before the `MoveTargetsCache` memo). At the user's current
4 collections; cost is **linear in folder count and paid twice per cell**, so a
40-folder library pays ~10×.

Replace with ONE `.contextMenu` at the grid container. The target cell is
resolved on demand by hit-testing the click point against the analytic frames —
`masonryMarqueeIndices` (`MarqueeMath.swift:77`) with a zero-size rect, the same
query the marquee already runs per drag tick. No new machinery. The content
closure then runs once per actual right-click instead of once per cell per
rebuild.

Two wrinkles to handle explicitly:
- **Cursor position** — stash the location from `.onContinuousHover` on the
  container and read it when the menu opens. A keyboard-invoked context menu
  (Menu key) has no hover position; fall back to the `lead` cell.
- **Lost system highlight** — per-cell `.contextMenu` draws the "targeted cell"
  outline for free. A container menu must draw it; the selection/cursor ring
  rendering already exists to build on.

The drag preview does **not** collapse the same way (a drag genuinely
originates from one cell). Deferring it — e.g. attaching `.draggable` only to
the hovered cell, since the pointer must be over a cell to start a drag — is
more delicate and is deliberately NOT bundled here.

### C2. Density (⌘±) tolerance

Buckets are coarse; most density steps stay in-bucket (zero re-decode). On
bucket change: paint instantly from the nearest cached bucket (≤ ~2× upscale
tolerated), re-request the exact bucket async, swap. No purging — byte
eviction reclaims old buckets.

### C3. Call-site migration

- The grid host computes the bucket from the analytic cell frame +
  `displayScale` and passes it down (cell never guesses its own size).
- `AsyncThumbnail`: `.task(id: hash+bucket)`, sync cached (bucket-tolerant) →
  placeholder → await pipeline → re-read.
- Fixed-size call sites pass literal buckets: `CoverCard`
  (`SharedThumbnail.swift:299`), `CollectionDropRail.swift:108`,
  `CollectionStackCard.swift:84` (128), drag preview
  (`CollectionView.swift:807`, 192). Default parameter 512 preserves behavior
  elsewhere.
- Prefetch: NSCollectionView's `prefetchItemsAt`/`cancelPrefetchingForItemsAt`
  → `pipeline.prefetch`/`cancelPrefetch`. (If any SwiftUI windowed path
  remains during migration: pure `masonryPrefetchIndices(...)` next to
  `masonryVisibleIndices` in `GridWindowing.swift`, driven from the
  band-change seam at `CollectionView.swift:410–438`.)
- Delete `ThumbnailCache` after all four call sites move.

---

## 5. Sequencing (REVISED after the bake-off — each step shippable, commit per step)

The ordering below is the amended one. C moves to the front because it is both
independently justified AND the experiment that decides whether A1–A4 happens
at all. A0/B are unaffected by the bake-off and keep their original content.

0. ~~Merge `6933a17` (skeleton-on-switch)~~ — **done** (`372cc57`).
1. **C1** — make `ImageDecoding` public + URL overload + byte cost;
   `ThumbnailPipeline` + bucket ladder + tests (pure). §4.1.
2. **C3** — migrate `AsyncThumbnail`/cover/rail/stack call sites; delete
   `ThumbnailCache`. §4.3.
3. **C4 (new)** — container-level lazy context menu. §4.5.
4. **DECISION GATE — re-run the bake-off.** Re-measure `swiftUIWindowed/full`
   at 200 and 2000 against the unchanged `appKit` mode, per `037` §3–§4.
   **RAN — see `039-grid-bakeoff-gate-results.md` for results, both configs, and
   the verdict-per-rule. Outcome: Not smooth with C complete; appKit Smooth. The
   A1–A4 go/no-go is left to the human, per the binding blocks below.**
   - SwiftUI reaches **Smooth** → **cancel A1–A4** (~9 days saved); the grid
     migration was moot. Delete the spike; keep the harness as a regression
     guard.
   - SwiftUI still **Not smooth** → the recycling gap is the real ceiling.
     Proceed to step 7 with the confound eliminated and evidence in hand.

   **Harness skew, found during C3 — read before running this.** The harness's
   SwiftUI modes build the *real* `CollectionCell`, so they DO inherit C1's
   off-main eager decode (the effect the §5 prediction is actually about). They
   do **not** inherit C3's bucketing: they never pass `bucket:`, so every cell
   takes the 512 default while production requests 128–512 sized to the cell.

   The skew runs one way — the harness is *pessimistic* relative to production.
   So a **Smooth** verdict is trustworthy (production is at least as good), but
   a **Not smooth** verdict is **not conclusive**, and the pre-registered rule
   turns exactly that verdict into a 9-day commitment.

   Therefore step 4 is run in **two configurations**, both reported:
   - **(a) harness as-measured** — one line unchanged, directly comparable to
     the `038` baseline. Answers "did C1+C3+C4 improve it, and by how much?"
   - **(b) harness passing production buckets** — the one-line `masonryCell`
     change. Answers "does the shipping configuration reach Smooth?", which is
     the question the gate actually decides on.

   Config (b) breaks byte-identity with `038`, which is why it is additive
   rather than a replacement: (a) preserves the before/after delta, (b) tests
   the absolute thresholds. The thresholds in `037` §4 are absolute, so (b) is
   legitimate to decide on; `appKit` is unchanged in both. **If (a) and (b)
   disagree, (b) governs the A1–A4 decision and the disagreement itself gets
   recorded** — it would mean thumbnail sizing, not framework, was carrying the
   difference.
5. **A0** — `GridSelectionStore` extraction. Unaffected by the gate: it is
   substrate for the AppKit coordinator AND a win on its own (it stops
   selection publishes invalidating every other view observing
   `IngestionModel`). Note §2 A0's claim that it alone stops whole-screen
   re-render is **overstated** — `CollectionView` reads `selection` at nine
   sites in its own body, so the parent still re-runs until those reads move
   down into per-cell views.
6. **B1–B4** — detail work. Independent of the gate.
7. *(only if the gate says so)* **A1 → A2 → A3 → A4** as originally specified.
8. `.change-log/` entries per landed step; mark 035 §7 deferred item done.

**Falsifiable prediction on record before step 4.** At 200 items with wrappers
stripped and a warm cache, the SwiftUI grid still measured Not smooth (7 frames
over 2P, worst 44 ms) — on a workload of ~200 plain images that any framework
should render effortlessly. That points at `NSImage` deferring pixel decode to
first draw, **on the main thread, mid-scroll**, producing a spike each time a
band crossing brings new cells on screen. C1's fully-decoded off-main bitmaps
target exactly this. If the prediction is right, step 4 cancels A1–A4.

**Widened after C1 — the prediction above stands as written, but its confidence
interval was too narrow.** Left in place deliberately rather than rewritten: it
was recorded as falsifiable, and quietly restating it after new evidence is the
exact failure mode `037` was written to prevent.

C1 measured the named mechanism as **real and quantified but partial**: it moves
~0.9 ms per newly visible cell off main ≈ **8–11 ms per band crossing** (8–12
new cells) against a **44 ms** measured worst frame. Right order of magnitude to
matter; wrong order to be the whole story. `038` §3.3 measured the per-cell
wrappers as the largest SwiftUI-side effect, which puts C1 in a comparable band
rather than a dominant one.

So: **C1 alone reaching Smooth is plausible, not expected.** This strengthens
`038` §5's closing suggestion that the cheap path is **C1 + C4 together**.

**Consequence for the gate, binding:** if step 4 is run after C1 only and
returns Not smooth, **that is not a framework verdict** and must not be recorded
as one. C4 has to land first. Running the gate early and reading it literally
would justify a 1–2 week rewrite off an admittedly incomplete comparison —
structurally the same error `038` §4 caught the first time.

## 6. Test strategy

**Unit (AtelierRefsTests, pure-function pattern):**

- `ThumbnailBucketTests` — ladder, monotonicity, 512 ceiling, density-step
  stability.
- `ThumbnailPipelineTests` — injected decode closure: coalescing (decode
  counted once), fallback-bucket order, cost eviction, prefetch cancel.
- `MostViewedReorderTests` — matches core sort tiebreak; identical array when
  unchanged (publish guard).
- `ViewBumpCoalescerTests` — per-id counts.
- `DetailNeighborsTests` — ends, single item, retainOnly after fast stepping.
- Workstream A: pure suites (`MasonryLayoutTests`, `MarqueeMathTests`,
  `GridSelectionTests`, `GridNavigationTests`, `GridDensityTests`,
  `GridReorderTests`, `QuickLookPlanTests`) untouched by design. New:
  `GridSelectionStoreTests`, `SelectionCellDeltaTests` (symmetric diff, lead
  moves, mode flip), `MasonryCollectionLayoutTests` (width change invalidates,
  scroll doesn't), `AssetDragPayloadTests` extension (NSPasteboard JSON ↔
  Transferable round-trip). `GridWindowingTests` dies with the windowing code
  in A4.

**Manual / Instruments:**

- SwiftUI template on 1000–2000 items: body-evaluation counts — open = nav
  publish (+optional lead), prev/next = zero grid body runs, close on
  Most-Viewed = one reorder publish after fade, no `loadContents`.
- Time Profiler: no draw-time `NSImage` decode on main during scroll; steady
  memory under cache budget; no re-decode thrash scrolling back; zero layout
  `prepare()` calls while scrolling.
- Animation Hitches: open/close fade, arrow stepping incl. a 40MP image
  (neighbor paints instantly), zoom-in swap without hitch.
- Functional: ⌘± repaints instantly then sharpens; delete-from-detail
  auto-dismisses; Most-Viewed rises after close; Space/search overlays
  unaffected; marquee/drag/drop/context menu/GIF hover/keyboard all survive
  the grid migration.

## 7. Baseline note: the merged tree (post `372cc57`)

This plan was researched on the windowing worktree, which did **not** contain
the 012 analysis line. After merging, the baseline also carries Vision OCR
(`VisionTextRecognizer`), `AssetAnalyzer`, `AnalysisBackfill`, perceptual
hashing, colour extraction, and smart collections. Two consequences:

1. **No current scroll contention.** `AnalysisBackfill` has no app-side call
   site — nothing in `AtelierRefs` invokes it, so no Vision work competes with
   scrolling today. The earlier "no background analysis contends" finding
   therefore still holds, but for a different reason than assumed: the pipeline
   exists and is simply not wired up yet.
2. **It becomes a smoothness hazard the moment it is wired up.**
   `AnalysisBackfill` states outright that it "does NOT own scheduling — QoS /
   idle-priority / pause-on-user-activity is the app's concern (012)". Whoever
   wires it must land that scheduling at the same time: idle-priority, paused
   while a collection is being scrolled or marquee-selected, and never on the
   same lane as visible thumbnail decodes (the `ThumbnailPipeline` prefetch gate
   in C1 is the natural place to arbitrate). Wiring it without that will undo
   the work in this plan.

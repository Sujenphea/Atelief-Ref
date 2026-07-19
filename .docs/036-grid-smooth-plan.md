# 036 — Collection grid smoothness: plan

Implementation plan for making the collection grid smooth end-to-end (scroll,
multi-select, detail open/step/close) at 500–2000 items. Companion to
`035-grid-scroll-perf-research.md`, which measured the scroll residual and
sketched the forward options; this plan takes **Option B** (AppKit
`NSCollectionView`) plus the selection split, the detail-view fixes, and the
thumbnail pipeline work that 035 §7 deferred.

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

### C1. New `ImageDecode.swift` + `ThumbnailPipeline.swift`

Replaces `ThumbnailCache` (`SharedThumbnail.swift:20–36`).

- `ImageDecode.downsampled(at:maxPixelSize:) -> (NSImage, byteCost)?` —
  `CGImageSourceCreateThumbnailAtIndex` with `ShouldCacheImmediately: true`
  (fully-decoded bitmap, EXIF transform, never materializes full-res). Shared
  with Workstream B.
- Pure bucket ladder `thumbnailPixelBucket(pointLongSide:scale:)` → snapped UP
  to {128, 192, 256, 384, 512}; 512 = tier ceiling.
- `ThumbnailPipeline` (singleton):
  - `cached(hash:bucket:)` — sync hit; falls back to nearest (prefer larger)
    cached bucket for instant paint.
  - `image(hash:url:bucket:) async` — `.userInitiated`, coalesced via
    `[ThumbnailKey: Task]`.
  - `prefetch([...])` / `cancelPrefetch(hashes:)` — `.utility` behind a
    max-4-concurrent gate; visible requests bypass and promote.
  - Cache: `NSCache` keyed `"hash#bucket"`,
    `totalCostLimit = clamp(physicalMemory/16, 128 MB...512 MB)`, cost =
    decoded bytes, no countLimit. API is hash+url+bucket only (no SwiftUI
    types) so both the SwiftUI path and NSCollectionView prefetching use it.

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

## 5. Sequencing (each step shippable, commit per step)

0. Merge `6933a17` (skeleton-on-switch) into this branch.
1. **A0** — `GridSelectionStore` extraction (kills whole-screen re-render on
   selection publish immediately; substrate for the coordinator).
2. **C1** — `ImageDecode` + `ThumbnailPipeline` + bucket fn + tests (pure).
3. **C3** — migrate `AsyncThumbnail`/cover/rail/stack call sites; delete
   `ThumbnailCache`; Instruments check.
4. **B1–B3** — `DetailSession` + `DetailImageLoader` + `CollectionDetailHost`;
   strip `openItem`/`loadPreview`/`previewImage`/tag fns from `IngestionModel`.
5. **B4** — per-id view-bump counts, `MostViewedReorder`, deferred close
   reload.
6. **A1** — AppKit grid read-only behind `AtelierUseAppKitGrid` flag (cells +
   prefetch built on the C1 pipeline).
7. **A2** — selection/mouse/hover/keyboard/density parity.
8. **A3** — drag/drop/menu/marquee/GIF parity.
9. **A4** — soak, flip default, delete old path (isolated commit).
10. `.change-log/` entries per landed step; mark 035 §7 deferred item done.

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

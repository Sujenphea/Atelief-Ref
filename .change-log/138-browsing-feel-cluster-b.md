# 138 — Browsing feel: masonry grid, density, Quick Look, motion, toasts (011 · Cluster B)

Implements **Cluster B** of `.docs/feature-todo/011-ux-features.md` (plan:
`.docs/027-browsing-feel-plan.md`): the collection grid becomes an
aspect-preserving **round-robin masonry** (B1) with a **density control** (B2),
gains **spacebar Quick Look** (B3), **capture-feedback toasts** (B4), and
**GIF-on-hover motion** (B5). **Zero schema** — entirely view/service layer over
existing rows. Retires 009's temporary uniform-grid marquee source, exactly as
that change-log anticipated ("replaced by 011").

## What ships

### B1 — Round-robin masonry grid
- **`MasonryLayout`** (pure) — item `i` → column `i % C`, aspect-sized cells
  stacked by cumulative column height; returns every item's frame (offscreen
  included) + content height + column width as pure data. Round-robin keeps feed
  order == visual order and a fixed `C`, so keyboard nav (`nextGridIndex`) and
  reorder (`GridReorder`) stay index-clean — no rewrite. Trade: ragged/lopsided
  column bottoms (accepted).
- **`aspect(for:)`** (pure) — the one clamped `w/h` helper, `[0.25, 4.0]`, built
  on `SpaceLayout.aspect`; media-less / zero / NaN → square `1` (so a panorama
  can't blow a column's height).
- **Render** — `HStack` of `C` `LazyVStack` columns (each `stride(from: col, by:
  C)`), cells framed to `columnWidth × columnWidth/aspect` so the render exactly
  matches the analytic frames. Replaces the old `LazyVGrid(.adaptive)`.
- **`ThumbnailTile.fill`** — a fill mode so byte images crop-fill their aspect
  cell; media-less cards stay square (aspect 1). Threaded through
  `AssetContentThumbnail` / `AsyncThumbnail` / `CollectionCell` (default `false`
  keeps every other surface square).
- **Marquee retarget** — `MarqueeCaptureLayer` now consumes the layout's real
  `[CGRect]` frames; the new band-narrowed `masonryMarqueeIndices` (x-range →
  hit columns analytically, y-monotonic binary search within a column) restores
  the O(cols + hits) 009 shipped, verified equal to the general core. Deleted the
  temporary `uniformGridFrames` / `uniformMarqueeIndices` / `uniformCellSide`.
- **`MasonryLayoutCache`** + `IngestionModel.itemsVersion` — frames recompute
  only on `(itemsVersion, width, columns)` change, so the marquee's per-tick
  selection churn (which re-renders the grid) is a memo hit, not an O(N)
  re-layout; scroll never touches the key.

### B2 — Density control
- **`GridDensity`** (pure) — a column-count notch, `zoomedIn`/`zoomedOut` clamped
  to `[minColumns(forWidth), maxColumns]` where `minColumns = ceil(width / 512)`
  enforces the 512px thumbnail-tier cap ([16A]): a density change is a pure
  re-layout + re-scale of already-cached thumbnails — no new tier, no backfill.
- **`GridViewPreferences`** — persists the notch globally (`UserDefaults`, one
  muscle memory across collections), clamped/defaulted on a corrupt load. Wired
  `ContentView → AppShellView → CollectionView`.
- **Controls** — a toolbar `ControlGroup` (larger/smaller, disabled at each end)
  + ⌘+/⌘−/⌘= from the focused grid, both clamped against the live viewport width.

### B3 — Spacebar Quick Look
- **`QuickLookController`** — the native shared `QLPreviewPanel` as data source
  over an array (flip / arrows / spacebar-dismiss / zoom free). Spacebar in the
  grid peeks the selection (or the keyboard-cursor item), flipping from the lead;
  the pure `quickLookPlan` skips media-less items and an all-media-less set no-ops.
- **`SpaceView` retrofit** — the canvas video peek moves onto the same panel; the
  divergent single-URL `QuickLookPresenter` (standalone `NSWindow`) is deleted.

### B4 — Capture-feedback toasts
- **`ToastQueue`** (pure) — coalesce-by-key (one toast per batch, never
  per-item), append-newest order, injected-clock expiry, visible-count cap
  (oldest evicted); `resolveJump` no-ops a toast that outlived its collection.
- **`ToastCenter`** + **`ToastHostView`** — a shell-level bottom-trailing overlay
  (hit-transparent empty space) driven by a single self-rescheduling purge timer.
- **Jump** — a landed browser-capture batch publishes `IngestionModel.CaptureBatch`;
  `ContentView` raises one "Saved N to <folder>" toast (coalesced per folder)
  with a typed Jump. Jump navigates + stages a **pending selection** that
  `loadContents` applies against the freshly loaded items (pure `jumpSelection`) —
  deterministic, not a timing hack.

### B5 — GIF hover motion
- **`shouldAnimateGif`** / **`gifWithinBudget`** (pure) — animate only a hovered
  GIF with Reduce Motion off and under a 24 MB budget; everything else stays a
  static poster.
- **Machinery** — `CollectionCell` dwell-gates (~150 ms) before decoding,
  `GifAnimationCoordinator` caps to ONE concurrent animation, `AnimatedGifView`
  plays the ORIGINAL blob via `NSImageView.animates` and releases frames on
  hover-out; Reduce Motion short-circuits before any decode. Video hover-preview
  stays deferred to v1.5.

## Schema / migration

**None.**

## Files changed

- New (app): `MasonryLayout`, `MasonryLayoutCache`, `GridDensity`
  (+ `GridViewPreferences`), `QuickLookController`, `ToastQueue`, `ToastHost`
  (`ToastCenter`/`ToastHostView`/`ToastCard`), `JumpSelection`, `GifMotion`.
- Edited: `MarqueeMath` (masonry hit-test, uniform source removed), `GridMarquee`
  (frame-fed capture layer), `SharedThumbnail` (`fill` mode), `CollectionCell`
  (`fill` + GIF hover), `CollectionView` (masonry render, density, Quick Look),
  `IngestionModel` (`itemsVersion`, capture batch, pending Jump selection),
  `ContentView` / `AppShellView` (gridPrefs + toast host), `SpaceView` (QL
  retrofit).
- Deleted: `QuickLookPresenter`.
- New tests: `MasonryLayoutTests`, `GridDensityTests`, `QuickLookPlanTests`,
  `ToastQueueTests`, `GifMotionTests`; `MarqueeMathTests` trimmed to the
  permanent core.

## Tests

App unit bundle green — **224 tests, 0 failures**. New pure suites cover the
masonry placement + degenerate matrix, the marquee band-narrow ≡ general-core
contract, density stepping + width-clamp + persistence round-trip/corrupt-clamp,
the Quick Look skip-media-less mapping, the toast queue (coalesce/expiry/cap) +
stale-Jump no-op + deterministic Jump selection, and the GIF motion decision +
budget + single-slot cap. Views stay compile-only per repo convention.

## Manual pass (pending)

Marquee feel over staggered cells, live density resize, QL window flip over a
multi-select, GIF hover dwell/teardown, and toast stacking + Jump. Watch for
round-robin raggedness reading lopsided on a run of tall images — shortest-column
balancing is the noted fallback (reopens 009's keyboard/marquee coupling).

## Notes

- Column count is the ONE source for both the layout and keyboard nav, so
  `nextGridIndex`'s `± columns` math always matches the frames.
- Density notch bounds (`maxColumns = 12`) and the toast stacking style
  (bottom-trailing) are the plan's build-time open questions, settled here.

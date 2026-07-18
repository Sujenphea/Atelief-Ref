# 035 — Collection grid scroll performance: research

Profiling investigation into collection-grid scroll lag, the windowing fix that
landed (see change-log 160), the measured residual, and the two forward options
with their costs. Companion to `035-*` if a design/plan is later split out.

## 1. The original problem

Scrolling the collection grid became laggy as item count grew. Root question:
was there any virtualization? **No** — the grid (011-B1) rendered EVERY item's
cell eagerly (`HStack` of per-column `VStack`s) so the cross-axis masonry layout
settled in one pass. Every cell was live regardless of viewport.

### Measured, not guessed

Time Profiler over a 20s hard scroll (real data, <200 items):

```
xcrun xctrace record --template "Time Profiler" --attach <PID> --time-limit 20s
```

~9.4s of main-thread work per 20s, split between:

- **SwiftUI layout ~7.4s** — `NSHostingView.layout` → `ForEachChild.update` →
  `masonryCell`. Scales with item count (all cells laid out every pass).
- **Hit-testing ~2.0s** — `NSScrollView.hitTest` →
  `ContentResponderHelper.containsGlobalPoints`. Also scales with count (the
  responder walk visits every live cell).

Thumbnail DECODE was OFF the main thread — not a factor. The bottleneck was
purely that every cell existed.

## 2. What landed: explicit windowing (change-log 160)

Only cells near the viewport are rendered, each placed ABSOLUTELY at its analytic
`MasonryLayout` frame. Key pieces:

- **`GridWindowing.swift`** (pure, unit-tested): `gridWindow` quantizes the scroll
  offset to a viewport-height BAND; `masonryVisibleIndices` / `windowedCells`
  filter to the visible slice; `hoverAfterWindowChange` reconciles stranded hover.
- **`CollectionView.masonryWindow`**: `ForEach` over only the visible cells, each
  `.offset` to its frame origin inside a ZStack whose height is the FULL content
  height (scrollbar + marquee hit-area still span the whole collection).
- **Quantized band**: the slice reads the PUBLISHED band, not the live offset;
  republished only when the band changes → re-materializes a few times per
  screenful, not once per tick.
- **One geometry source**: the analytic frames (which already drove the marquee)
  are re-used for placement, so render position == frame by construction. Marquee,
  keyboard nav, reorder, selection all keep operating over the FULL frames,
  independent of what's rendered — behavior unchanged.

## 3. Before / after (same trace methodology)

| Path | Baseline | Post-windowing | Change |
|---|---|---|---|
| Hit-testing (`NSScrollView.hitTest → containsGlobalPoints`) | ~2,027 ms | **385 ms** | ↓ 5.3× |
| Cell render/rebuild (`masonryCell`) | ~1,502 ms | 763 ms | ↓ 2× |
| ForEach child update | ~1,745 ms | 842 ms | ↓ 2× |
| `dragPreview` / `cellMenu` | 378 / 326 ms | 230 / 122 ms | ↓ (cellMenu via `MoveTargetsCache` memo) |
| Main thread IDLE (`nextEvent`) | 67% | **86%** | much more headroom |

The hit-testing walk is structurally gone (the big win). Main thread went from
~33% busy to ~14% busy — the "much smoother" the eyeball test reported.

## 4. The residual ("not the smoothest")

Dominated by **`masonryCell` (763 ms) + `ForEachChild.updateValue` (842 ms)** —
the **band-boundary re-materialization**, felt as a periodic per-screenful hitch
rather than continuous lag.

Mechanism, in code:

- `masonryWindow` (`CollectionView.swift:520`) is
  `ForEach(cells) { masonryCell(...) }`. On each band republish, SwiftUI
  re-evaluates that closure for EVERY windowed cell (~4 screenfuls).
- `masonryCell` (`:531`) reconstructs the whole per-cell tree each time: the
  `ZStack`, `.draggable { dragPreview }` (`:563`), `.dropDestination` (`:564`),
  `.contextMenu { cellMenu }` (`:567`), `.onHover`, `.animation`.
- The `.equatable()` at `:561` guards ONLY the inner `CollectionCell` body — the
  entire wrapper rebuilds unconditionally.

Net: a band crossing re-materializes ~100 cell wrappers when maybe 8–12 actually
entered/left the window.

## 5. Forward options

### Option A — Equatable windowed cell (recommended)

Hoist `masonryCell`'s output into a dedicated `struct MasonryCellView: View,
Equatable`, with `==` comparing exactly the value inputs that affect rendering
(`item.id`, `frame`, `isSelected`, `isCursor`, `isSelecting`, `showsCircle`,
thumbnail/gif URL, `moveTargets`) and the closures built INSIDE `body`. SwiftUI's
diff then skips `body` for every unchanged cell — a band crossing costs ~a dozen
rebuilds, not ~a hundred. Collapses the 763 + 842 ms directly.

- **Effort**: ~half a day. **Risk**: contained to one struct.
- **Perf**: removes ~80% of the residual hitch.
- **Risk surface**: every appearance-affecting input MUST be in `==`, or that
  cell goes stale. This is the whole risk, and it is testable: unit-test the pure
  `==`, plus a regression test that a selection/hover change on cell *k*
  invalidates cell *k* (guards the classic omitted-field Equatable bug).
- **Fit to prefs**: `==` lists every reactive input by name (explicit over
  clever); pure function → well-tested; no architectural churn.

### Option B — AppKit `NSCollectionView` (the "big" change)

Replace the SwiftUI windowed `ForEach` with `NSCollectionView` + `NSScrollView`
via `NSViewRepresentable`, using AppKit's native cell RECYCLING (dequeue/reuse).
"Older" framework, but the mature specialized tool for large scrolling grids —
SwiftUI's grid virtualization immaturity is why windowing had to be hand-rolled.

What it costs:

- **Bridge layer**: `NSViewRepresentable` + `Coordinator` (dataSource/delegate) +
  a custom `NSCollectionViewLayout` emitting the masonry frames (flow layout
  won't do round-robin masonry).
- **Cells become `NSView` again**: either host each SwiftUI `CollectionCell` in an
  `NSHostingView` (reintroduces per-cell hosting cost, partially defeating the
  point) or rewrite the cell in AppKit for the clean win.
- **State bridged by hand**: hover (`NSTrackingArea`), context menu (`menu(for:)`),
  drag/drop (`NSDraggingSource`/`Destination`), and model → `reloadItems` pushes.
  Replaces the reactive `@Observable` flow with imperative reloads.
- **Preserve/re-verify**: marquee/nav/reorder/selection SURVIVE (they ride the pure
  analytic frames), but the marquee OVERLAY + auto-scroll move into AppKit's
  flipped `documentView` coordinate space. `GridWindowingTests` becomes moot
  (recycling is native) — new bridge/layout tests replace it.

| | A · Equatable cell | B · AppKit `NSCollectionView` |
|---|---|---|
| Effort | ~half a day | 1–2 weeks, high uncertainty |
| Risk / blast radius | one struct | selection, hover, drag, drop, marquee, GIF |
| Perf ceiling | ~80% of residual hitch | native-smooth, best possible |
| New failure modes | stale cell (testable) | flipped coords, first-responder, hosting leaks, reload flicker |
| Fights architecture? | no | yes — reactive flow → imperative reloads |

### Option C — do nothing

Ship windowing as-is. Main thread has ample headroom (86% idle) and the residual
is a small per-screenful hitch. Defensible at current scale.

## 6. Recommendation

Take **Option A** now — it buys the large majority of the smoothness for ~a day
at near-zero architectural risk. **Option B** is the correct long-term substrate
IF this grid is central and must scroll thousands of items buttery-smooth; only
reach for it if profiling AFTER Option A still shows band hitches at the item
counts actually shipped (<200 today, downsampling deferred for >512 — see 160).

## 7. Deferred / tracked

- Thumbnail downsampling + byte-based cache limit (`SharedThumbnail.swift`) for
  collections over ~512 items — not the <200-item bottleneck this addressed.
  Complementary to the parallel 012 shared-decode work.

# 027 — Browsing Feel (Cluster B) — Implementation Plan

> Implements **Cluster B** of `.docs/feature-todo/011-ux-features.md`: aspect-
> preserving grid (B1), density control (B2), spacebar Quick Look (B3), motion
> policy (B4), and capture-feedback toasts (B5). Plan reviewed interactively across
> four lenses (architecture, code quality, tests, performance); decisions settled
> below. **Zero schema** — Cluster B is entirely view/service-layer over existing
> rows.
>
> **Layout choice (revised):** the grid uses **round-robin fixed-column masonry**
> (item `i` → column `i % C`, variable cell heights by aspect), NOT justified rows.
> Round-robin keeps a clean row index (`row = i/C`), so keyboard nav and reorder
> stay index-clean; the trade is unbalanced/ragged column bottoms (accepted). See
> "Layout decision" below.

## Layout decision: round-robin masonry vs justified rows

Both preserve aspect ratio (fixing today's square-crop) and both virtualize
cleanly (transpose of each other). Round-robin masonry was chosen because it keeps
the **feed order == visual reading order** and a **fixed column count**, which
means:

- Keyboard nav keeps the existing `current ± columns` index math — no rewrite.
- Reorder (009 `GridReorder`) stays coherent — drop index == visual position.
- Marquee band-narrowing stays cheap (per-column y-monotonic).

Rejected alternatives:
- **Justified rows** — tidy on all edges but variable items-per-row forces a
  frame-based `nextGridIndex` rewrite; no aesthetic win worth it here.
- **Shortest-column ("true Pinterest") masonry** — balanced bottoms, but feed
  order ≠ visual order breaks keyboard nav, marquee ordering, and reorder. Not
  worth the reconciliation cost.

Accepted cost of round-robin: column bottoms are ragged and a run of tall images
in one column can look lopsided (no balancing).

## Context: the 009 coupling

009 (`123-multiselect-move.md`) shipped the marquee against a **deliberately
temporary** uniform-square frame source (`MarqueeMath.uniformMarqueeIndices`,
`MarqueeMath.swift:91`), annotated "replaced by 011-U2." The marquee hit-test
*core* (`marqueeIndices(in:frames:)`, `:36`) is already layout-agnostic — takes
`[CGRect]`. Under masonry, cells **stagger vertically** (variable heights), so the
uniform-square source is wrong and must be replaced by real `MasonryLayout` frames.
Keyboard nav (`nextGridIndex`, `GridNavigation.swift:27`) stays as-is — round-robin
preserves the fixed-column index structure it already assumes.

## Settled decisions

### Architecture
- **[1A′] `MasonryLayout` — standalone pure helper.** New pure `MasonryLayout`
  computing, for a viewport width + column count + per-item aspect: each item's
  frame (`x = col·(w+gap)`, `w = colWidth`, `h = colWidth/aspect`, `y = running
  height of column `i%C``) and total content height (`max` column height).
  **No shared primitive with `SpaceLayout`** — masonry is a different algorithm
  (fixed-column cumulative stacking, not width-budget row cutting), so there is
  nothing to extract. Only DRY thread that survives is the shared `aspect()` helper
  ([6A]). The `CanvasContent.layout` ↔ `SpaceLayout.flowIn` duplication is a
  fully-orthogonal later cleanup.
- **[2A′] One frame source, keyboard nav unchanged.** `MasonryLayout` emits the
  canonical `[CGRect]` array; feed it to the existing `marqueeIndices` core. Delete
  the temporary `uniformMarqueeIndices`/`uniformGridFrames`. **Keep `nextGridIndex`
  as the existing `current ± columns` index math** — round-robin's fixed C columns
  make it correct; only the column count `C` must be sourced from the layout.
- **[3A′] Render via `LazyHStack` of column `LazyVStack`s.** C columns side by
  side; column `c` renders `stride(from: c, to: N, by: C)` in a `LazyVStack` of
  aspect-sized cells. Virtualization free (each column lazy-vertical). Analytic
  frames must match render (asserted — see [9A]). Replaces the current
  `LazyVGrid(.adaptive)` (`CollectionView.swift:41`).
- **[4A] Toasts get their own pure model.** New `ToastQueue` (coalescing/expiry/
  ordering, tested) + a **shell-level** host overlay carrying a typed `Jump`
  action. Existing `status` line + `.alert` keep their current roles.

### Code quality
- **[5A′] Density = column count.** Pure `GridDensity` value type: notches map to
  **column counts**, `stepUp/stepDown` clamped to `[minColumns(forWidth), maxCols]`
  where `minColumns(forWidth) = ceil(width / 512)` enforces the [16A] tier cap.
  Width-parameterized but still pure + tested. Persisted via a thin
  `GridViewPreferences` owner using the existing `UserDefaults.standard` pattern
  (no `@AppStorage` convention exists yet). Keeps notch logic out of the ~1.7k-line
  `IngestionModel`.
- **[6A] Aspect input.** One shared `aspect(for: CollectionItemDetail) -> Double`
  helper (consolidated with `SpaceLayout.aspect`), **clamped to `[0.25, 4.0]`**;
  media-less kinds / zero / missing → `1.0`. Pure, tested against a degenerate
  matrix. Under masonry, aspect drives cell **height** (`colWidth/aspect`); clamp
  guards 0-dim → NaN and a portrait panorama → an unbounded-tall column.
- **[7A] Quick Look via native `QLPreviewPanel`.** Move grid QL to
  `QLPreviewPanel` + a `QLPreviewPanelDataSource` over the current selection
  (native flip/arrows/spacebar-dismiss free); media-less items skipped/placeholder.
  **Retrofit `SpaceView` onto the same path** (removes the divergent single-URL
  `QuickLookPresenter` NSWindow route).
- **[8A] Motion scope = GIF hover only.** Gate on `asset.mimeType == "image/gif"`,
  animate from the **original blob** on hover, tear down on exit, Reduce-Motion
  aware. Video hover-preview explicitly deferred to v1.5. Decision behind a pure
  `shouldAnimate(asset:reduceMotion:isHovering:)` helper.

### Tests
- **[9A′] Frame-feed contract suite.** Real `MasonryLayout` frames drive
  `marqueeIndices`; property tests across column count × width × item count;
  structural invariants (per-column frames non-overlapping and y-monotonic;
  **render position == frame**). Keyboard nav tested separately as index math
  consistent with `C`.
- **[10A′] `MasonryLayout` degenerate + property matrix.** empty/1/N,
  fewer-items-than-columns (trailing empty columns), one very-tall image (one long
  column), single column (`C=1`), many columns, density extremes; invariants: all
  frames in-bounds, positive heights, no NaN, `contentHeight == max column
  height`, column membership == `i % C`.
- **[11A] `ToastQueue` full suite.** Coalescing (one toast per batch), ordering,
  auto-expiry removal order, rapid-duplicate dedup, stack cap (oldest evicted),
  **stale-Jump-target no-op**, injectable clock (no wall-clock).
- **[12A] Failure paths + design the Jump race away.** Density round-trip +
  corrupt/out-of-range → clamp to default (incl. width-derived min columns);
  `shouldAnimate` matrix; QL "skip media-less" pure mapping test. Jump routes
  through a **pending-selection id applied *after* `loadContents`** (deterministic
  + unit-testable), not a timing hack. UI-only bits on a manual checklist.

### Performance
- **[13A′] Band-narrowed marquee hit-test.** Marquee rect x-range → hit columns
  (analytic, `i % C`); within each hit column, frames are y-monotonic → binary
  search the y-band → O(columns_hit · log N + hits). Restores the O(hits) 009
  shipped (`123-multiselect-move.md:99`). Verified against the general core.
- **[14A] Memoized layout.** Frames recompute only when `(items identity/count,
  viewport width, column count)` changes; resize coalesced; scroll never touches
  the key → zero recompute on scroll (mirrors 009's cached-id discipline).
- **[15A] GIF hover discipline.** Decode only after ~150 ms hover dwell; cap **1**
  concurrent animation; release frames on hover-out; skip animation over a
  frame/byte budget (stay static); Reduce-Motion short-circuits *before* decode.
- **[16A] Cell width capped at the 512px tier.** Density's minimum column count is
  `ceil(width / 512)`, so cell width stays ≤ 512px → pure re-layout + re-scale of
  already-cached thumbnails, no new tier, no library backfill, no extra memory. A
  larger tier (1024 + backfill) is a separate future slice.

## Component map

| New/changed | Kind | Purpose |
|---|---|---|
| `MasonryLayout` | pure | grid frames as `[CGRect]` + content height [1A′][2A′] |
| `aspect(for:)` helper | pure | clamped aspect input (drives height) [6A] |
| `GridDensity` | pure | column-count notches + width-clamped step [5A′][16A] |
| `GridViewPreferences` | model | persist density (+ future view prefs) [5A′] |
| `ToastQueue` | pure model | coalescing/expiry/ordering + typed action [4A] |
| Toast host overlay | view | shell-level presentation [4A] |
| `shouldAnimate(...)` | pure | GIF-hover motion decision [8A][15A] |
| masonry marquee band-narrow | pure | O(cols·logN + hits) hit-test [13A′] |
| `CollectionView` grid body | view | LazyHStack-of-columns render [3A′] |
| grid Quick Look | view/AppKit | `QLPreviewPanel` data source [7A] |
| `SpaceView` QL | view | retrofit onto `QLPreviewPanel` [7A] |
| GIF hover animator | view | dwell-gated animated decode [8A][15A] |
| keep `nextGridIndex` | — | existing index math reused (round-robin) [2A′] |
| delete `uniformMarqueeIndices`/`uniformGridFrames` | — | temporary source retired [2A′] |

## Phased implementation

Dependency order: **B-1 first** (foundation, couples with 009). B-2 depends on
B-1. **B-3, B-4, B-5 are independent** after B-1 and may land in any order.

1. **B-1 (M–L) — Masonry grid.** `MasonryLayout` [1A′] + clamped `aspect(for:)`
   [6A] + `LazyHStack`-of-columns render [3A′] + frame feed to `marqueeIndices`
   [2A′] + band-narrowed hit-test [13A′] + memoization [14A]; delete the temporary
   uniform source; keep `nextGridIndex` (sourcing `C` from the layout).
   *Tests:* [9A′] contract + [10A′] matrix. Land in the **same window** as retiring
   the 009 uniform path (009 §N6 risk note).
2. **B-2 (M) — Density.** `GridDensity` (column-count notches, width-clamped) +
   `GridViewPreferences` [5A′][16A]; ⌘+/⌘− + toolbar slider stepping notches.
   *Tests:* notch stepping, width-derived min-columns clamp, round-trip +
   corrupt-value clamp [12A].
3. **B-3 (M) — Spacebar Quick Look.** `QLPreviewPanel` data source over selection
   [7A]; multi-select flip; media-less skip; retrofit `SpaceView`.
   *Tests:* skip-media-less pure mapping [12A]; manual QL pass.
4. **B-4 (M) — Capture toasts.** `ToastQueue` [4A] + shell host + one-toast-per-
   batch on the bulk path; Jump via pending-selection [12A].
   *Tests:* [11A] full suite + deterministic pending-selection Jump test.
5. **B-5 (M) — GIF hover motion.** `shouldAnimate` [8A] + dwell-gated animated
   decode + single-animation cap + Reduce-Motion + budget fallback [15A].
   *Tests:* `shouldAnimate` matrix [12A]; manual hover pass.

## Consolidated test strategy

- **Pure, exhaustive** (repo convention): `MasonryLayout` [10A′], frame-feed
  contract [9A′], `aspect(for:)` degenerate matrix [6A], `GridDensity` stepping +
  width clamp [5A′], `ToastQueue` [11A], `shouldAnimate` [8A], band-narrow ≡
  general core [13A′], density persistence round-trip/clamp + QL skip-media-less +
  Jump pending-selection [12A].
- **Manual pass** (views compile-only): marquee feel over staggered cells, QL
  window flip, density column-count live-resize, GIF hover dwell/teardown, toast
  stacking + Jump.

## Performance contract

- Marquee: O(cols·log N + hits) per tick [13A′]; frames memoized, recomputed only
  on (items, width, column count) change [14A]; no re-render on scroll.
- Density: pure re-layout + re-scale of cached 512px thumbnails; cell width ≤ 512px
  by the min-column clamp; no re-decode, no backfill [16A].
- GIF: at most one concurrent animation, dwell-gated, torn down on exit [15A].
- No new DB queries with N+1 characteristics — B1 reuses `collectionItems(in:sort:)`
  (one joined query); B5 reuses the existing reload funnel.

## Risks & edge cases

- **Frame == render invariant.** Column cells stagger by cumulative height, so the
  analytic frames must exactly match the `LazyVStack` column positions or
  marquee drifts. Enforced by the render==frame assertion in [9A′]; live-resize
  must recompute [14A].
- **Ragged/lopsided columns.** Accepted trade of round-robin (no balancing); a run
  of tall images in one column reads long. If it looks bad in the manual pass,
  revisit (shortest-column is the balanced alternative but reopens 2/13/reorder).
- **Degenerate aspect input.** 0-dim, negative, NaN-inducing, portrait-panorama —
  clamped/guarded in [6A]; covered by [10A′].
- **Reduce Motion** must short-circuit before any GIF decode [15A].
- **Stale Jump target.** A "Saved — Jump" toast can outlive its collection/asset —
  no-op gracefully [11A][12A].
- **Jump async race.** `loadContents` is async; select via pending-selection
  applied post-load, not a timer [12A].
- **QL media-less items** (color/link/tweet) have no blob URL — skip in the data
  source, never blank/crash [7A].
- **Density × width.** On very wide windows the min-column clamp raises C so cells
  stay ≤ 512px; on very narrow windows a single column is valid (`C=1`).

## Deferred / out of scope

- `CanvasContent.layout` ↔ `SpaceLayout.flowIn` merge (separate cleanup).
- Video hover-preview loop (needs a pooled `AVPlayer`) — v1.5 [8A].
- 1024px thumbnail tier + library backfill — future, only if [16A]'s cap proves
  too small.
- Per-kind aspect ratios (tweet portrait, etc.) — layer onto [6A] later if wanted.
- Shortest-column (balanced) masonry — only if round-robin's raggedness proves
  unacceptable in the manual pass.

## Open questions to confirm at build time

- Density notch set: exact column-count values (e.g. small=8-notch cap … large=min
  columns) and the max column count.
- Toast position/stacking style (011 open-Q 4: bottom-trailing stack recommended).

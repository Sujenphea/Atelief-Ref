# 086 — Canvas Pinch Smoothing (018 · C7)

> **Outcome (2026-08-11): Phases 0, 1 and 3 shipped; Phase 2 was NOT built.** The gate
> below was run and the smoothing did not clear it — see
> [087](./087-canvas-pinch-results.md) for the numbers and for the larger problem the
> measurement turned up instead (per-frame cost scales with visible tile count, and a
> pan pays it identically). This document is left as written, because a plan that
> records what it expected is worth more afterwards than one edited to match the
> result. Two of its guesses were wrong and are worth naming: H1 (glyph re-raster) is
> small, and H3 — the hypothesis added almost as an afterthought — is the whole cost.
>
> The last live remainder of [018](./feature-todo/018-canvas-direct-manipulation.md).
> Six of its seven phases shipped; C7 is "perf harness + pinch smoothing", and 018's
> own sequencing advice is to **run the harness first and let it say whether the
> smoothing is needed at all**. This plan holds to that: Phase 0 is a measurement
> with a threshold written down *before* the run, and Phase 2 exists only if Phase 0
> fails it.
>
> Verified against the tree 2026-08-11.

## What the pinch path is today

`CanvasHostView.magnify(with:)` (`:746`) is three lines — convert the location,
`engine.zoom(by:aroundScreenPoint:)`. Per **event**, that fans out to:

| Step | Where | Cost per event |
|---|---|---|
| full `sync()` | `CanvasEngine.swift:813` | cull over ALL provider tiles, reposition every visible layer, re-tier LOD, `retainOnly` |
| text re-raster | `TextRenderLayer` (`needsDisplayOnBoundsChange`) | every visible text layer re-rasterizes: `drawScale` changed |
| decode churn | `DecodeScheduler.retainOnly` (`:60`) | a tier crossed → new decodes requested; the next event may cancel them |
| editor reposition | `CanvasHostView.swift:563` | `NSTextView` frame recomputed |
| app chrome | `SpaceView.swift:434` → `SpaceTextChromeAnchor.refresh()` | a `@Published` write (guarded by a `CGRect` compare) |
| camera write | `SpaceView.swift:437` → `SpaceModel.cameraChanged` (`:322`) | a debounce `Task` cancelled and recreated |

`NSEvent.phase` is never read anywhere in the file, so there is **no gesture** in
this design at all — only a stream of independent zooms that happen to arrive close
together. Everything below needs that bracket first.

## What 018's reconnaissance says, checked against our tree

018 §E4 records two non-obvious traps from Easel's implementation. **Neither applies
here**, and that is the single biggest reason this phase is smaller than the doc
predicts:

1. *"`zPosition` alone will not composite above AppKit's subview-managed layers"* —
   irrelevant. The engine's whole layer tree lives on one dedicated layer-hosting
   `CanvasSurfaceView` (`CanvasHostView.swift:541–553`), and the only thing above it
   is the inline editor, a real subview. A gesture-scoped transform on
   `engine.rootLayer` composites correctly beneath it with **no snapshot overlay** —
   the piece of Easel's design that exists purely to cover the reveal.
2. *"text must be laid out at a reference point size or line height snaps on
   release"* — already structural. `TextRenderLayer` (060) shapes in **world** units
   under a `ShapeKey` that scale is deliberately not part of; a zoom changes only
   `drawScale`. Gesture-scaled and settled renders therefore differ in *resolution*
   and nothing else. Line breaks cannot move.

This is [059](./059-spaces-text-render-overview.md)'s rejected "Option A —
gesture transform-scale" becoming free: it was rejected as a stopgap for text
*stability*, and Option B shipping made stability a property of the layout instead.

**The trap 018 does not record, and the one that shapes this plan:** culling keeps
only visible tiles plus a `prefetchMarginScreen` = 200pt ring (`CanvasEngine.swift:31`).
A pure GPU scale-**down** magnifies the viewport over world space that has no layers
in it — blank margins until release. That is a correctness failure, not softness, and
it is why the strategy below is a hybrid rather than a clean freeze-and-commit.

## Suspected costs (hypotheses — Phase 0 exists to rank them)

Stated up front so the measurement can confirm or kill them rather than being read
backwards from whatever it finds:

- **H1 — text raster.** Every visible `TextRenderLayer` re-rasterizes per event via
  CoreText. The existing `testGlyphTextWithinBudgetAcrossZooms` measures exactly this
  and passes headlessly, but it measures raster *driven into a bitmap*, not the render
  server's real per-frame budget alongside compositing.
- **H2 — LOD/decode churn.** A pinch sweeping a tier boundary requests decodes and
  cancels them on the next event. `retainOnly` cancels the `Task`, but the decode work
  is largely already paid — `Task.isCancelled` is checked *after* `loadAndDecode`
  returns (`DecodeScheduler.swift:52`). Wasted CPU on a `.userInitiated` queue,
  competing with the main thread, plus a visible pop when the new tier finally lands.
- **H3 — cull cost.** `currentVisibleTiles()` is O(N) over the whole provider and is
  called from `sync()` **and** again from `snapCandidates` / `handleTile` /
  `tile(atScreenPoint:)`. Only `sync()` is on this path, but a dense board pays it
  per event.
- **H4 — app-side per-event work.** A `Task` allocated and cancelled per event for the
  camera debounce; a SwiftUI publish while an edit is open.

**Nothing currently measures H2 at all.** `testFrameUpdateWithinBudget` is the image
path but pans with a pre-warmed cache; `testGlyphTextWithinBudgetAcrossZooms` zooms
but is text-only. Decode churn under zoom — the thing a pinch actually provokes —
falls between them.

## Phase 0 — the harness and the gate

Reuse rather than port. 018 §E3 suggests adapting Easel's `EaselPerf.swift`; we
already have the better instrument, built for exactly this class of question in
[037](./037-grid-bakeoff-protocol.md): `FrameTimeRecorder` +
`frameTimeStatistics(intervalsMs:refreshPeriodMs:)`, a pure statistics core with its
own tests (`FrameTimeStatsTests`) and a display-link shell that contains no
arithmetic. It reports p50/p95/p99, hitch counts against the **real** refresh period,
and the longest frame — the tail, which is what a pinch complaint is about.

Two instruments, because they answer different questions:

**0a — `CanvasPinchDriver`** (app-side, `AtelierRefs/Debug/`), mirroring
`BakeoffScrollDriver`: one scripted zoom sweep driven off the recorder's *own*
display link, so a zoom step can never land between two sampled frames. Integrates
each frame's real `dt` (not tick counts) so a 120Hz and a 60Hz machine sweep the same
zoom range in the same wall-clock time and their runs stay comparable — the same
reasoning `BakeoffScrollDriver` records for scroll distance. Drives
`engine.zoom(by:aroundScreenPoint:)` directly rather than synthesizing `NSEvent`s;
the event plumbing is not what is being measured.

**0b — a headless `CanvasBenchmark` case**: image path, **cold cache**, pinch-cadence
zoom sweep. The CI-gated regression guard, and the only thing that can catch H2.

**Pre-registered decision rule.** Over a **3-second** scripted sweep on a mixed
**~500-tile** board (images + text) at the real display refresh, smoothing is
justified if **either**:

- **p99 > 2× the refresh period** (a fat tail — a visible stutter, not jitter), or
- **> 2% of frames exceed the refresh period** (sustained hitching).

Both triggers, not a mean. 037 chose percentile-and-count pairing precisely because a
mean rated the old grid "fine" while periodic 40–80ms frames were the actual
complaint; the same failure mode is available here. Record the refresh period with
every run (a laptop on an external monitor has two different answers).

If Phase 0 passes on both triggers, **Phase 2 is not built** — Phase 1 lands on its
own merits and C7 closes with a number.

## Phase 1 — the gesture bracket (unconditional)

Small, independently correct, and a prerequisite for Phase 2 either way.

1. **Read `NSEvent.phase`** in `magnify(with:)`. `.began` → `engine.beginGestureZoom(anchor:)`,
   `.changed` → `updateGestureZoom(factor:)`, `.ended`/`.cancelled` → `endGestureZoom()`.
   Guard against a missing `.began` (a gesture already in flight when the view
   appears) by treating any `.changed` without an open gesture as an implicit begin —
   the same defensive shape `resetGestureState()` takes for the mouse path.
2. **Freeze LOD for the gesture.** Pin each visible tile's tier at `.began` and
   re-tier once at settle. Kills H2 outright and removes mid-pinch tier pops. A deep
   zoom-in stays at the start tier until release — consistent with the GPU-scaled
   frames being bitmap-scaled anyway, so the two halves of the gesture agree.
3. **Coalesce to vsync.** At most one `sync()` per frame, regardless of event rate.
4. **Coalesce callbacks.** Suppress `onTransformChanged` and `onCameraChanged` for
   the gesture's duration; fire each once at `.ended`. With the edit committed and
   chrome hidden (below) nothing is listening that needs per-event fidelity, and the
   camera debounce sees one write per pinch instead of ~120 `Task` create/cancel pairs.
5. **Commit any open edit at `.began`**, exactly as clicking away does. The editor is
   an `NSTextView` subview outside the scaled tree; there is no honest position for it
   against a transform that is not real yet.
6. **Hide chrome for the gesture** — resize handles, snap guides, selection borders.
   They are screen-space-constant by design and live inside the same `rootLayer` a
   Phase 2 scale would apply to, so they would visibly thicken and swell. Hiding is
   also what makes counter-scaling per frame unnecessary, on the exact path being
   optimised.

## Phase 2 — gesture-scoped GPU scale (conditional on Phase 0)

**Hybrid: scale between syncs, re-sync on band exit.**

- While the gesture runs, accumulate the factor and apply
  `CATransform3DTranslate · Scale · Translate` about the pinch anchor as
  `rootLayer.sublayerTransform`, inside a `CATransaction` with actions disabled (the
  same discipline `sync()` already uses).
- **Force a real sync** — commit the accumulated factor into `engine.transform`, reset
  `sublayerTransform` to identity in the *same* transaction — whenever either:
  - the accumulated factor leaves a band of roughly **±15%** (matched to
    `LODPolicy.hysteresis`, so a band exit and a tier change are the same event rather
    than two independent stutters), or
  - a scale-down would expose more than `prefetchMarginScreen` of unlayered margin.
    Computable exactly: the revealed ring is `viewportSize × (1/factor − 1) / 2`.
- On `.ended`: one final commit, identity transform, re-tier LOD, restore chrome, fire
  the coalesced callbacks.

The reset-and-commit must be atomic. A commit that lands in a different transaction
from the identity reset shows one frame at double the scale — the classic version of
this bug, and the reason the two lines are written together with a comment saying so.

## Phase 3 — tests

The gesture seam lives on `CanvasEngine`, not the view, so it is testable headlessly
without an `NSEvent` (which a `swift test` process has no way to make — the same
constraint that produced `resizeHandleForTesting`). `CanvasPinchTests`:

- **Sync budget** — N gesture updates produce ≤ ⌈N/band⌉ syncs, read off the existing
  `syncCount`. The assertion that the smoothing does anything at all.
- **Terminal equivalence** — a gesture of factors `f₁…fₙ` about an anchor leaves
  `transform` equal, within epsilon, to the same zooms applied directly. The
  smoothing must be invisible in the result.
- **Identity after end** — `rootLayer.sublayerTransform` is the identity once the
  gesture closes, from every exit (`.ended`, `.cancelled`, and a teardown mid-gesture).
- **Anchor is a fixed point** — the world point under the anchor is unmoved across the
  whole gesture, including across a band-exit re-sync. This is the one that catches an
  off-by-a-transaction commit.
- **Band exit on reveal** — a scale-down past the prefetch ring forces a sync even
  when the factor is still inside the ±15% band.
- **LOD freeze** — no new cache key is requested mid-gesture; the tier changes exactly
  once, at settle.
- Layer transform and chrome hiding: compile-only + a manual pass (repo convention for
  the visual half), recorded in the changelog with the Phase 0 before/after numbers.

## Settled decisions (2026-08-11)

| # | Decision |
|---|---|
| D1 | **Measure first, gate on it.** Phase 2 ships only if Phase 0 fails the pre-registered rule. |
| D2 | **Hybrid scale + band re-sync**, not a pure freeze-and-commit — the zoom-out reveal is a correctness issue. |
| D3 | **Chrome hidden, edit committed** at `.began`. No counter-scaling. |
| D4 | **Both harnesses**: in-app scripted driver for the verdict, headless cold-cache bench as the CI gate. |
| D5 | **LOD frozen** for the gesture, re-tiered once at settle. |
| D6 | **`onTransformChanged` + `onCameraChanged` fire once, at `.ended`.** |
| D7 | **Pinch only.** ⌘-scroll / wheel zoom is a real gap but a separate feature; see Open questions. |
| D8 | **Rule:** p99 > 2× refresh period, **or** > 2% of frames over the refresh period, on a 3s sweep over a ~500-tile mixed board. |

## Risks

- **The gate passes and this closes with no smoothing.** That is a success, not a
  waste: the harness is the deliverable 018 asked for first, and it becomes the
  regression guard for the renderer's zoom path regardless.
- **Bitmap softness while zooming in.** Inherent to any GPU-scale approach, and the
  LOD freeze (D5) extends it to the image path deliberately. If it reads badly, the
  band tightens — that is the one tuning knob, and it trades softness back for syncs.
- **The band-exit sync is itself the hitch.** If a single `sync()` is what blows the
  budget, doing it every ±15% only reduces the frequency. Phase 0's ranking of H1–H3
  is what says whether the answer is fewer syncs or a cheaper sync (a spatial index
  for the cull, H3).
- **A gesture that never ends.** `.cancelled` is delivered inconsistently in practice;
  a stuck gesture would leave the tree permanently scaled and chrome permanently
  hidden. `viewDidMoveToWindow` / `viewWillMove(toWindow:)` must close an open gesture,
  the same way they already close an open edit and the marquee's auto-pan link.
- **Committing the edit at `.began`** changes behaviour: a pinch mid-sentence now ends
  the edit. Defensible (it matches clicking away, and losing typed text is the failure
  that actually matters) but it is a user-visible change and belongs in the changelog.

## Open questions

1. **⌘-scroll / wheel zoom** (D7) — deferred, and recorded here rather than dropped.
   The engine seam should be written phase-agnostic so driving it from a second
   gesture later is wiring, not a redesign. `scrollWheel` (`:742`) also ignores
   momentum phase today, which the same bracket would want.
2. **Cull cost (H3)** — if Phase 0 ranks it first, the fix is a spatial bucket, which
   is its own doc. 018 §Risks already flags the peer case for snap candidates
   ("measure before optimizing, but do measure").

## Effort

**Phase 0: S–M · Phase 1: S · Phase 2: M · Phase 3: S.** Zero schema. Phase 2 is
conditional; Phases 0, 1 and their tests land regardless.

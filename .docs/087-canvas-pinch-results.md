# 087 — Canvas Pinch: Measurement Results and the C7 Verdict

> The gate [086](./086-canvas-pinch-smoothing-plan.md) promised, run. Its rule (D8)
> was written down before any of these numbers existed and is evaluated in code
> (`CanvasPinchVerdict`), so the outcome could not be rationalised afterwards.
>
> **Verdict: the pinch smoothing — 086 · Phase 2, the gesture-scoped GPU scale — is
> NOT justified, and was not built.** Phase 1 (the gesture bracket) shipped on its own
> merits. What the measurement found instead is a larger problem that no amount of
> pinch smoothing would have touched: see §4, which is the part of this document worth
> keeping.

## 1. How these were produced

- **On-screen** — `-canvas-pinch-bakeoff`
  (`AtelierRefs/Debug/CanvasPinchBakeoff.swift`): a scripted pinch over a synthetic
  board, sampled by 037's `FrameTimeRecorder` at the display's real refresh.
  **Release** build (a Debug number is not a verdict — 037 §3.1), Built-in Retina
  Display, 60Hz, so `P` = 16.67ms and `2P` = 33.3ms. Viewport 1440×900, 3s sweep, 8x
  magnification in and back out, 2 zoom events per vsync (a ~120Hz trackpad against a
  60Hz panel).
- **Headless** — `CanvasBenchmark.testPinchGestureCutsDecodeRequests` and
  `testPinchCostsNoMoreThanPanning`, via `swift test` in `CanvasRenderer`.

Both are checked in and re-runnable. Every on-screen run writes its raw per-frame
intervals into its export, so a run can be re-scored against a different refresh
period without repeating it.

```
-canvas-pinch-bakeoff arm=both,tiles=500,duration=3,repeats=2,events=2,out=/tmp/pinch.json
```

## 2. On-screen: a ~500-tile board is smooth, before and after

| arm | cache | frames | p50 | p95 | p99 | max | over `P` |
|---|---|---|---|---|---|---|---|
| direct (pre-086) | cold | 180 | 16.67 | 16.67 | 33.33 | 41.0 | 4/180 (2.2%) |
| direct | warm | 179 | 16.67 | 16.67 | 16.67 | 16.67 | 0/179 |
| gesture (086) | cold | 180 | 16.67 | 16.67 | 16.67 | 27.9 | 1/180 (0.6%) |
| gesture | warm | 179 | 16.67 | 16.67 | 16.67 | 16.67 | 0/179 |

Essentially every frame lands on the vsync. The only blemish is the **cold** sweep's
handful of long frames — first-decode work, never repeated on the warm sweep.

Against D8: p99 never reaches `2P`; hitching is 0–2.2%, and the one reading that
grazes the 2% trigger is four frames of cold start on the *unsmoothed* arm. At the
pre-registered board size the pinch was already smooth, so **the smoothing has
nothing to fix.**

## 3. On-screen: past ~1,200 tiles everything is over budget, pinch or not

1,200 tiles, 2 events per vsync, each arm run cold and warm:

| arm | p50 | p95 | p99 | max | over `P` |
|---|---|---|---|---|---|
| **pan (control — no zoom at all)** | 16.67 | 51.8 / 53.1 | 58.4 / 54.0 | 63.1 | **38.3% / 38.0%** |
| direct | 16.67 | 77.4 / 70.4 | 109.3 / 77.8 | 125.4 | 45.6% / 38.3% |
| gesture | 16.67 | 47.2 / 44.6 | 73.6 / 59.0 | 81.2 | 38.1% / 36.8% |

And at 3,000 tiles (1 event per vsync), both pinch arms sit around **p50 = 53ms,
63–64% of frames over `P`** — roughly 18fps.

**The control is the finding.** A pan of the same board — the camera moving with no
zoom, no LOD churn, no glyph re-raster — hitches on 38% of frames, indistinguishable
from a pinch. Whatever is over budget here is not the pinch.

### A run that did not reproduce

One earlier single sweep of the gesture arm at 1,200 tiles / 2 events came back
perfect: 0 of 179 frames over `P`. Repeated under the same configuration it hitched
on 36.8–38.1%, in line with everything else. It is recorded here rather than quietly
dropped, because it is the one result that would have supported a much stronger claim
for the bracket, and it did not hold up. Run-to-run variance at this board size is
large; single sweeps at 1,200+ tiles should not be trusted.

## 4. What the cost actually is

Headless, 5,000-tile board, everything visible:

| what the camera is doing | per-frame |
|---|---|
| **nothing** (repeated `sync()`, camera still) | **11.9ms** |
| panning | 11.2ms |
| pinching (gesture bracket, one commit per frame) | 9.6–10.3ms |

A pinch is the *cheapest* of the three, because zooming in shrinks the visible set
while a standstill re-sync does not. The per-frame cost is `sync()` itself — the cull
walks the whole provider, then every visible tile gets its layer geometry — and it
scales with the **visible tile count**, at roughly 2.4µs per visible tile on this
machine. The 120Hz budget is crossed somewhere near **3,500 visible tiles** whatever
the camera is doing; the on-screen numbers in §3 put the practical ceiling lower
still, because compositing that many real image layers costs more than the sync does.

This is 086 · H3, and it was the least-suspected hypothesis going in:

- **H1 — glyph re-raster under zoom.** Real but small: 2.4ms for 144 overlays, and a
  zoom sweep costs no more per frame than a standstill on a text board.
- **H2 — decode churn.** Real, and now fixed (§5).
- **H3 — cull + layer sync scaling with visible count.** The dominant cost, by a
  wide margin, and it is paid identically by a pan.

**A gesture-scoped GPU scale would not have helped**, except incidentally by skipping
syncs — and skipping syncs is exactly what it cannot do while zooming *out*, because
the culler holds no layers for the world it would reveal (086's amendment to 018's
trap list).

## 5. What the bracket did buy

**Decode churn, measured** (`testPinchGestureCutsDecodeRequests`, cold cache,
identical camera trajectory in both arms, 5,000 tiles):

```
pinch decode requests: per-event=6890  gesture=6504  saved=386 (6%)
```

386 decodes — every tile that crossed an LOD boundary mid-sweep — are no longer
requested during the gesture and cancelled a frame later by `retainOnly`. They are
deferred to settle and requested once. The percentage is modest because most requests
on a cold board come from tiles *entering* the viewport, which are deliberately not
frozen (a frozen new tile would be a blank one). What it removes is pure waste: that
work was paid for on the decode queue and thrown away.

**Per-event fan-out, not measured but not in doubt.** A 2-second pinch used to fire
~240 `onTransformChanged` notifications, each repositioning the inline editor,
publishing into SwiftUI, and cancelling-and-recreating the camera-persistence debounce
task (`SpaceModel.swift:334`). It now fires one, at settle. The harness window holds a
bare `CanvasHostView`, so none of that app-side work is in these numbers.

**Frame time: within noise.** On the boards where the pinch is smooth, both arms are
smooth; on the boards where it is not, both arms are not. The coalescing only pays in
the narrow band where one sync fits a frame and two do not, and this instrument could
not resolve that band reproducibly.

## 6. Verdict, applied

| 086 phase | outcome |
|---|---|
| Phase 0 — harness + gate | **shipped** — `CanvasPinchBakeoff` (on-screen) + two `CanvasBenchmark` cases (headless) |
| Phase 1 — gesture bracket | **shipped** — phased `magnify`, vsync-coalesced commits, LOD freeze, one notification at settle, edit committed at `.began` |
| Phase 2 — GPU scale | **not built** — the gate says it is not justified |
| Phase 3 — tests | **shipped** — `CanvasPinchTests`, 19 cases |

018 · C7 closes here: the harness exists, it was run, and it answered the question it
was built to answer. The answer was no.

## 7. What this opens instead

**Per-frame cost scales with visible tiles, with no ceiling.** The renderer is smooth
to somewhere around 1,000 visible tiles and unusable past a few thousand, regardless
of gesture. Two directions, neither scoped here:

1. **Cull cheaper.** `currentVisibleTiles()` walks the entire provider every sync
   (`CanvasEngine.swift:256`) and is called more than once per frame on some paths. A
   spatial index makes the cull O(visible) instead of O(board). 018 §Risks flags the
   same shape for snap candidates — "measure before optimizing, but do measure". This
   is the measurement.
2. **Stop drawing a layer per tile when the tiles are pixels.** Past some visible
   count, one layer per tile is the wrong representation; the on-screen numbers say
   compositing is as much of the cost as the sync. Drawing the far-zoomed-out board
   into a single layer would decouple both from tile count.

Either is a bigger piece of work than C7 was, and both are now backed by a number
rather than a suspicion.

## 8. Honest limits of the harness

- **The driver is frame-paced.** It delivers `events` zoom events per vsync (default
  2). At `events=1` the two pinch arms are identical by construction — there is
  nothing to coalesce — so the default is what makes the comparison meaningful at all.
- **It measures the renderer, not `SpaceView`.** A bare `CanvasHostView`, so the app's
  floating chrome and camera-persistence debounce are outside the measured frame.
- **One machine, one 60Hz display.** The refresh period is recorded in every export
  and the raw intervals are kept, so a ProMotion run compares directly.
- **A stalled run fails loudly.** If the display sleeps or the window is not shown, no
  vsync arrives and the sweep would hang forever; a watchdog exits with
  `BakeoffExitCode.noFrames` and says which of those it was. This fired twice during
  these sessions — hence the caveat above about single sweeps.

# 381 — The Pinch That Stopped Asking Twice

018's last unshipped phase (C7 — "perf harness + pinch smoothing") said to build the
harness *first*, because it is the instrument that says whether the smoothing is
needed at all. So that is the order this took, and the harness said **no**.

What shipped is the half nobody was arguing about: `magnify(with:)` is now a
**gesture** instead of a stream of unrelated zooms. What did not ship is the
gesture-scoped GPU scale [086](../.docs/086-canvas-pinch-smoothing-plan.md) planned
for, because the measurement refused it — and turned up something bigger on the way
past. The numbers are in [087](../.docs/087-canvas-pinch-results.md).

## 1 · There was no gesture, only events

`NSEvent.phase` was never read anywhere in `CanvasHostView`. A pinch arrived as ~120
independent `engine.zoom(by:aroundScreenPoint:)` calls per second, and each one paid
for everything: a full `sync()`, an inline-editor reposition, a SwiftUI publish, and a
cancel-and-recreate of the camera-persistence debounce task. A two-second pinch was
~240 of each.

Now the phases bracket it. `CanvasZoomGesture` — pure, 70 lines — accumulates the
factors; a `CADisplayLink` commits at most once per vsync; the transform notification
fires **once**, at settle. Zoom composes by multiplication, so committing the product
of a batch is exactly equivalent to committing each factor in turn — that equivalence
is the whole licence for the coalescing, and `CanvasPinchTests` pins it against a
per-event control.

Three things fall out of having a gesture at all:

- **LOD tiers are frozen for its duration.** A sweep crossing a tier boundary used to
  request a decode that the next event cancelled (`DecodeScheduler.retainOnly`) —
  paying for work on the `.userInitiated` queue and throwing the result away.
  Measured: **386 such decodes** over one 5,000-tile sweep, now deferred to settle and
  requested once. A tile with no tier yet is *not* frozen; freezing a tile that just
  entered the viewport would freeze it blank.
- **An open text edit commits at `.began`.** The editor is an `NSTextView` subview
  positioned from the transform the gesture is deliberately withholding until settle;
  left open, it would sit still while the board zoomed out from under it. Committing
  (not abandoning) matches what clicking away already does.
- **A gesture that never moves leaves no trace** — no sync, no notification, no camera
  write. Two fingers resting on a trackpad is not a camera change.

An unclosed gesture is closed rather than replaced (`.cancelled` is not reliably
delivered), and leaving the window closes one too — otherwise a leaked gesture would
keep the tiers frozen and the notification suppressed for every pinch after it.

## 2 · The harness, and the gate it was asked to answer

`-canvas-pinch-bakeoff` runs a scripted pinch over a synthetic board and samples it
with 037's `FrameTimeRecorder` at the display's real refresh — percentiles and hitch
counts, not a mean, because a mean is what rated the old grid "fine" while every tenth
frame stuttered.

It reuses 037's stack wholesale rather than porting Easel's `EaselPerf`, which 018 §E3
suggested; we already had the better instrument, with a pure tested statistics core.
Two details are load-bearing:

- **It emits `events` zoom events per vsync (default 2).** At one event per frame the
  two arms are identical *by construction* — there is nothing to coalesce — so a
  frame-paced driver would have scored the bracket at exactly zero however good it was.
  A real trackpad reports at ~120Hz; on a 60Hz panel that is two.
- **It has a `pan` arm.** "Is a pinch expensive?" has no meaning except against what
  the same board costs when the camera moves *without* zooming. That control is what
  settled the verdict.

A watchdog exits with a diagnosis if no vsync arrives within the sweep's duration plus
ten seconds, rather than hanging a driving script forever on a file that is never
written. It fired twice during these sessions, both times because the display had
slept.

## 3 · What the numbers said

At ~500 tiles (the board size 086's rule was pre-registered against), the **unsmoothed**
pinch already lands every frame on the vsync — p99 = 16.67ms against a 33.3ms trigger,
0–2.2% hitching against a 2% one, and the reading that grazes it is four frames of cold
start. Nothing to fix.

At 1,200 tiles, everything is over budget — and a **pan** of the same board hitches on
38% of frames, indistinguishable from a pinch. Headlessly, at 5,000 visible tiles, a
repeated `sync()` with the camera *standing still* costs 11.9ms/frame, a pan 11.2ms,
and a pinch 9.6–10.3ms. The pinch is the cheapest of the three, because zooming in
shrinks the visible set.

So the cost was never pinch-specific. It scales with the **visible tile count** — the
cull walks the whole provider every sync — and a GPU scale during the gesture would
have papered over a pan-shaped problem. 087 §7 carries that forward; it is a bigger
piece of work than C7 was, and now has a number behind it rather than a suspicion.

One earlier sweep of the gesture arm came back perfect (0 of 179 frames over budget)
and did not reproduce. It is written down in 087 rather than quietly dropped, because
it is the single result that would have supported a much stronger claim for the
bracket.

## Tests

`CanvasPinchTests` — 19 cases, all headless. The gesture seam lives on `CanvasEngine`
rather than the view precisely so they can exist: a `swift test` process has no way to
make a phased `magnify` event, so anything reachable only through `magnify(with:)`
could only ever be checked by hand.

What they pin: a coalesced gesture lands on the *same* transform as event-by-event
zooms; a mid-gesture commit is invisible in the result; the anchor's world point is
fixed across the whole gesture including across a commit; accumulating does not sync
and a whole gesture costs two syncs rather than one per event; the notification fires
once; a motionless gesture leaves no trace; an unclosed gesture is closed rather than
leaked; a zero, negative or non-finite factor cannot collapse or mirror the board; and
tiers stay frozen mid-gesture but re-tier at settle.

Two `CanvasBenchmark` cases were added, and one of them is a comparison rather than a
budget: `testPinchCostsNoMoreThanPanning` asserts a pinch frame costs no more than a
pan frame on the same board. An absolute 120fps assertion there would have been a claim
about board density wearing a name that says "pinch" — the printed numbers carry it
instead. Its board is also **denser** than the pan benchmark's: a 10x zoom into the
sparse clustered board lands the viewport between clusters (1,887 tiles visible at the
start, *zero* at the top of the sweep), and a sweep that ends up looking at nothing
would have quietly reported that the freeze saves nothing.

The full renderer suite passes: 437 Swift Testing cases + the XCTest benchmarks.

Plus a **manual pass** on a real board in a Release build, which is the only way to
check the half none of the above can reach: how the coalesced pinch actually feels,
and whether committing an open edit at `.began` reads as correct rather than as
losing your place. Both fine.

## Files changed

- `CanvasRenderer`: `CanvasZoomGesture.swift` (new), `Host/CanvasEngine.swift`
  (gesture seam, LOD freeze), `Host/CanvasHostView.swift` (phased `magnify`, commit
  link, public `zoom`/`pan`/`setCamera` for the harness),
  `Tests/CanvasPinchTests.swift` (new), `Tests/CanvasBenchmark.swift`
- `AtelierRefs`: `Debug/CanvasPinchBakeoff.swift` (new), `Debug/GridBakeoffWindow.swift`
  (one line — an app has one delegate, and 037's already holds the seat)
- `.docs`: `086-canvas-pinch-smoothing-plan.md`, `087-canvas-pinch-results.md`,
  `feature-todo/018-canvas-direct-manipulation.md` (C7 closed)

## Migration notes

Nothing to run, no schema change. One user-visible behaviour change: **pinching while
a text box is open now commits that edit** (§1). Callers of `CanvasHostView` gain
`zoom(by:aroundScreenPoint:)`, `pan(byScreenDelta:)`, `setCamera(_:)` and the three
gesture methods; nothing existing changed signature.

# 489 — the status that was published and never received

## Summary

Reported against the release build: **"the video player doesn't work — it shows the
initial frame, and when playing, the same frame is shown."**

The "initial frame" is the **poster** — `.change-log/383` draws it on top of the
`VideoPlayer` to cover the wait to `.readyToPlay`, and `ThumbnailTier.makeVideoPoster`
renders it from a frame about a second into the clip. It is an opaque JPEG. While it
is up the player underneath plays perfectly and the picture never changes, because the
picture on screen is a still.

**The root cause is that `AVPlayerItem.status` reached `.readyToPlay` and the gate
never heard about it.** Not cancellation, not a stuck player, not AVKit — a dropped
Combine value:

```swift
for await status in item.publisher(for: \.status).values { … }
```

`AsyncPublisher` requests **one value at a time and buffers nothing**. A value
published while no `next()` is pending is discarded. KVO for `status` fires on an
arbitrary background thread, so it can land in the window between two iterations of
the consuming loop — and `status` transitions exactly **once**, `.unknown` →
`.readyToPlay`. Losing that single delivery means the wait never ends, the poster
never lifts, and the player plays on underneath it for the life of the page.

Measured in the shipped build, not argued:

```
13:07:07.935  gate: entered
13:07:08.077  gate: status 0        ← .unknown, the .initial value
13:07:11.081  lifted: backstop      ← forced at 3s; nothing in between
```

One delivery, then silence, while the video played.

## The fix

`ItemDetailView.statusStream(for:)` replaces the Combine publisher with an
`AsyncStream` over `item.observe(\.status, options: [.initial, .new])`, buffering
policy `.bufferingNewest(1)`. A value yielded between iterations now waits instead of
vanishing. `.bufferingNewest(1)` is the right policy for a state variable: only the
latest status has meaning, and an older one arriving late says nothing the newer one
does not. `.initial` is kept so an item already ready when the observation starts
still reports, rather than waiting on a transition that has already happened.

After, same build, two opens:

```
13:09:47.275 entered → 47.598 status 0 → 47.815 status 1 → lifted   (540 ms)
13:09:58.635 entered → 58.710 status 0 → 58.916 status 1 → lifted   (281 ms)
```

No backstop. `status 1` is `.readyToPlay`.

## Two other defects, found on the way, neither of them the cause

Both are real and both are fixed here, but **neither produced the reported symptom**.
Worth saying plainly rather than letting the changelog imply a tidier story than the
debugging had.

**1. The wait lifted the poster on one exit out of three.** `for await` over an
`AsyncPublisher` does not throw on cancellation — it ends, and the function returns
normally. The old code set `videoReady = true` *inside* the loop, so a cancelled task
or a completed publisher returned with the flag still false, `player` already
assigned, and `.task(id: asset.id)` unable to re-run for an unchanged id. A genuine
stranding bug; simply not the reported one. `VideoPosterGate.firstFrame` now invokes
`lift` from a `defer`, so every path out drops the poster.

**2. The poster was hit-testable.** It is opaque and drawn over `AVPlayerView`'s own
transport controls, so a click aimed at Play landed on a picture. Now
`.allowsHitTesting(false)`, scoped to the poster branch and **not** to the `ZStack`,
which would take the player's clicks with it.

## The backstop

`loadMedia`'s `.video` arm arms an unstructured `Task` that lifts the poster after 3s
regardless. `VideoPosterGate` guarantees the poster lifts on every *return* from the
wait; it cannot guarantee the wait returns. This is the ceiling for that, and it is
what turned an invisible hang into a 3-second hitch while the cause was still unknown.

Unstructured on purpose: it must outlive an `awaitFirstFrame` that suspends
indefinitely, which a child task would not. Cancelled on the ordinary path, on
navigation, and in `onDisappear`. 3s is ~30× the 92.4 ms `VideoOpenProbeTests` measured
for `.readyToPlay`.

It stays now that the cause is fixed. It costs nothing on a healthy open (cancelled
after ~300 ms) and it is the difference between a future regression here being a hitch
or being an unusable player.

## What the debugging cost, and why

Four rebuild-and-retest rounds, two of them wasted by the instrument rather than the
bug:

- **The gate logged only at its RETURN points.** A gate entered and then suspended
  forever produces exactly the same silence as one never called — and those need
  opposite fixes. Entry logging plus a line for *every* status, `.unknown` included,
  is what finally made the trace readable. Log the entry, not just the exits.
- **The lines were `AppLog.detail.debug`.** Debug-level logging is off by default and
  enabling it needs root, so in a Release build those lines were never recorded no
  matter what the code did. An empty log was read as "the code never ran" when it
  meant "the instrument was never on". They are `.notice` now — persisted by default,
  a handful of lines per video opened.

## Files changed

- **`AtelierRefs/AtelierRefs/ItemDetailView.swift`** — `statusStream(for:)` replaces
  the Combine publisher (the fix); the 3s backstop and its three cancellation points;
  the poster branch gets `.allowsHitTesting(false)`; `import OSLog`.
- **`AtelierRefs/AtelierRefs/VideoPosterGate.swift`** (new) — the gate, its three
  exits, the `defer` that makes every one of them a lift, and entry/per-status logging.
- **`AtelierRefs/AtelierRefs/Diagnostics.swift`** — an `AppLog.detail` logger category.
- **`AtelierRefs/AtelierRefsTests/VideoPosterGateTests.swift`** (new) — five tests over
  the gate's exits, each asserting the lift COUNT rather than the returned reason.
  Verified to fail against the pre-fix shape before being trusted.

## Still open

**The poster is still DRAWN above the playback controls.** `.allowsHitTesting(false)`
lets clicks through; it does not stop the poster painting over them. That is inherent
to 383's overlay arrangement, and the choice — keep the overlay, or draw the poster
*instead of* the player until ready so the two never coexist — reverses a documented,
measured decision, so it is not taken unilaterally here.

**`statusStream(for:)` has no test.** The gate's exits are covered; the stream that
feeds it is not, and the stream is where the bug actually was. A KVO-backed
`AVPlayerItem` is awkward to drive from a unit test, but "a value yielded between
iterations is not dropped" is assertable against a plain `AsyncStream` and should be.

## Verification

`AtelierRefsTests` 2209 passed. Debug and Release both build. Behaviour confirmed
against the installed Release build by the log traces above.

## Migration notes

None. No schema, no stored state, no API used outside the app target.

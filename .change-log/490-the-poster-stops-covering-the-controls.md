# 490 — the poster stops covering the controls

Closes the two items `.change-log/489` left open.

## 1. The poster stands in place of the player, not on top of it

489 fixed why the poster never came down. It did not fix what the poster covered
while it was up: an opaque JPEG in a `ZStack` above `VideoPlayer` occludes AVKit's
transport controls as well as the picture. `.allowsHitTesting(false)` let clicks
through but not light — the controls stayed invisible, which reads as a player that
does not work whether or not the clicks land.

383's reasoning for putting it on top was sound and is worth restating rather than
deleting: `AVPlayerView` paints opaque black from the moment it is installed, so a
poster BEHIND it is invisible for exactly the window it exists to cover. The flaw was
never the z-order — it was that the two views are on screen together at all.

```swift
if let player, videoReady {
    VideoPlayer(player: player)
} else if let image = mediaImage {
    image.resizable().scaledToFit()
} else {
    ProgressView()
}
```

There is no z-order to get right between views that never coexist, and no control bar
to occlude. `.allowsHitTesting(false)` goes with the overlay: nothing sits under the
poster now, so suppressing its hits would only cost the media area's own tap-to-focus
and drag-out.

**The cost is smaller than 383's number suggests.** Of the 92.4 ms it measured
(`VideoOpenProbeTests`, 640×480), **1.1 ms is constructing the player** — the rest is
the wait to `.readyToPlay`, which `loadMedia` still begins immediately and still spends
behind the poster. Deferring construction moves 1.1 ms, not 92. An `AVPlayerItem`
reaches `.readyToPlay` through its `AVPlayer`, not through whatever is drawing it, so
the gate works with no view installed.

**What is actually given up**, stated plainly because it is a real regression against
383's intent: the black frame AVKit paints between being installed and drawing its
first frame is no longer hidden by anything. It is paid once, after the ~300 ms the
poster already covers.

## 2. The no-drop property is now pinned

489's bug lived one layer below everything its tests covered: the gate was correct, its
SOURCE was not. Two tests in `VideoPosterGateTests` state the property Combine's
`AsyncPublisher` lacked — a status produced while the consumer is not sitting at
`next()` must still reach the gate:

- `statusYieldedBeforeConsumptionSurvives` — both statuses produced before the gate
  consumes anything. An unbuffered source drops both; a buffered one keeps the newest,
  the only one carrying information.
- `statusYieldedMidWaitReachesTheGate` — `.unknown` consumed, gate back to awaiting,
  `.readyToPlay` arrives after. The 50 ms sleep is not what makes it pass (buffering
  covers both orderings, so it cannot flake on timing); it is there so the gate is
  genuinely between iterations when the second status lands, which is the condition
  that lost the value.

**Still uncovered, deliberately:** these drive the gate with a hand-built
`AsyncStream`. They do NOT exercise `ItemDetailView.statusStream(for:)` itself, so a
regression that swapped the KVO bridge back to `item.publisher(for:).values`, or
changed its buffering policy, would not fail them. Closing that needs a real
`AVPlayerItem` and a fixture clip — considered and declined as slower and
timing-dependent.

## Files changed

- **`AtelierRefs/AtelierRefs/ItemDetailView.swift`** — `mediaArea`'s `.video` arm swaps
  the `ZStack` overlay for a three-way branch; `.allowsHitTesting(false)` removed with
  the overlay that needed it.
- **`AtelierRefs/AtelierRefsTests/VideoPosterGateTests.swift`** — the two no-drop tests.

## Verification

`AtelierRefsTests` 2211 passed, all seven `VideoPosterGateTests` among them.

The 3s poster backstop from 489 stays. It costs nothing on a healthy open — cancelled
after ~300 ms — and it is the difference between a future regression in this area being
a hitch and being an unusable player.

## Migration notes

None.

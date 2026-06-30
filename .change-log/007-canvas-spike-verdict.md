# 007 — Canvas spike: CA-vs-Metal verdict

**Checkpoint 7** (final) of the Phase 1 canvas rendering spike.

## Summary

Recorded the spike's verdict (decision **A1**): **Core Animation is sufficient
for the MVP; Metal is deferred.** The benchmark cleared the 120fps budget with
~45% headroom at the P13 target, so we proceed CA-first and do not build the
Metal renderer now. A brief Metal fallback design is documented in case a future
benchmark regresses.

## Result recap

~2,069 tiles realized · ~4.6 ms/frame (budget 8.33 ms) · ~1 MB cache · ~38 MB
peak. See `.docs/005-canvas-overview.md` for the full write-up, caveats, and the
Metal fallback sketch.

## Files changed

- `.docs/005-canvas-overview.md` *(new)* — durable verdict + spike outcome +
  Metal fallback design.

## Verification

- `swift test` — full suite green (66 Swift Testing + 2 XCTest benchmark cases).
- `xcodebuild build -scheme AtelierRefs` — app builds with the live canvas
  harness.
- Manual (recommended, by hand): run AtelierRefs and confirm smooth pan (scroll)
  / zoom (pinch) over the ~5k-tile board; optionally profile with Instruments
  (Core Animation + Allocations) for true on-screen fps.

## Phase 1 status

**Complete and de-risked.** The `CanvasRenderer` package — pure logic, the
`TileProvider` seam, the CA host, and the perf benchmark — is ready to carry into
build-order step 2 (data core) and step 5 (productionize against real data).

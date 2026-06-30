# 006 — Canvas spike: performance benchmark

**Checkpoint 6** of the Phase 1 canvas rendering spike.

## Summary

Added the XCTest performance benchmark (decision **T10**) — the spike's go/no-go
gate. It measures the **main-thread per-frame cost** (cull + layer sync) at the
P13 target with the cache pre-warmed, so off-main decode (P15) is correctly
excluded, and records memory for regression baselines.

## Decisions realized

- **T10** — `measure(metrics:)` records `XCTClockMetric` + `XCTMemoryMetric`; a
  hard `XCTAssertLessThan` per-frame budget assertion is the pass/fail gate that
  runs headlessly under `swift test` (no stored baseline needed). Real on-screen
  fps stays a manual Instruments check.
- **P13** — runs at ~5,000 tiles, 1440×900 viewport, 120fps ⇒ 8.33ms/frame.

## Measured result (this machine)

- **~2,069 tiles realized**, **per-frame cull+layer-sync ≈ 4.6 ms** — comfortably
  under the **8.33 ms** 120fps budget.
- Resident thumbnail cache **~1 MB**; process memory peak **~38 MB** — bounded,
  scaling with the *visible* set as required.

→ **Core Animation clears the bar at the P13 target.** See `.docs/005` (CP7) for
the full verdict.

## Files changed

- `Tests/CanvasRendererTests/CanvasBenchmark.swift` *(new)* —
  - `testFrameUpdateWithinBudget`: hard per-frame budget gate over 240 panned
    frames;
  - `testFrameCostMetrics`: `measure` clock + memory baseline, asserts the cache
    stays under its ceiling;
  - `Duration.milliseconds` helper.

## Verification

- `swift test --filter CanvasBenchmark` — both cases pass; logs the per-frame ms
  and cache MB.
- `swift test` — full suite green (66 Swift Testing + 2 XCTest benchmark cases).

## Migration notes

None — tests only. The benchmark carries into build-order step 5 as a CI
regression guardrail.

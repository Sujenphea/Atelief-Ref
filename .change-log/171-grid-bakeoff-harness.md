# 170 — Grid bake-off measurement harness

The measurement rig for the three-way grid bake-off (`.docs/037`), which decides
whether the 1–2 week `NSCollectionView` rewrite (035 Option B / 036 Workstream A)
is justified. This is the HARNESS only — it implements no grid.

Throwaway spike code, isolated under `AtelierRefs/Debug/` so the whole thing
deletes as a folder, EXCEPT the pure statistics function and its tests.

## Summary

- **Frame-time recorder.** `CADisplayLink` sampling (vended by an `NSView`, the
  macOS API — mirrors the shipping `DisplayLinkPump`), with all arithmetic in a
  pure, unit-tested `frameTimeStatistics(intervalsMs:refreshPeriodMs:)`:
  count, duration, mean, p50/p95/p99 (nearest-rank), longest frame, hitch counts
  at the absolute 60Hz budgets (>16.7ms, >33.4ms) AND at the display's real
  period (>P, >2P), plus the mechanical 037 §4 verdict.
- **Scripted scroll driver.** Ramps offset 0 → travel at constant velocity over a
  fixed duration (default 10s), stepped once per display-link tick, integrating
  each frame's REAL duration so a 120Hz and a 60Hz machine scroll the same
  distance in the same wall-clock time. Driver and recorder share one link.
- **Bake-off window.** Opens under `-grid-bakeoff`; mode picker over
  `GridBakeoffMode` (`swiftUIWindowed` / `swiftUIEquatable` / `appKit`), wrapper
  picker over `GridBakeoffWrapperConfig` (`full` / `stripped`, per 037 §2), Run
  button, results table, text + JSON export.
- **Plug-in seam.** One `View` struct per mode, each in its own file with a fixed
  name and initializer, so three agents implement in parallel without touching
  shared code and a missing entry is a compile error.

## Files changed

New, all under `AtelierRefs/AtelierRefs/Debug/`:

- `FrameTimeRecorder.swift` — pure `frameTimeStatistics` + `FrameTimeStats` +
  the recording shell and its display-link host.
- `BakeoffScrollDriver.swift` — `BakeoffScrollTarget` protocol,
  `BakeoffScrollDriver`, and ready-made `SwiftUIScrollPositionTarget` /
  `NSScrollViewBakeoffTarget` conformances.
- `GridBakeoffSeam.swift` — `GridBakeoffMode`, `GridBakeoffWrapperConfig`,
  `GridBakeoffContext`. **The contract.**
- `SwiftUIWindowedBakeoffGrid.swift` — the baseline, implemented.
- `SwiftUIEquatableBakeoffGrid.swift` — placeholder (035 Option A agent).
- `AppKitBakeoffGrid.swift` — placeholder (035 Option B agent).
- `GridBakeoffWindow.swift` — the window shell, results, export, launch hook.

New test: `AtelierRefsTests/FrameTimeStatsTests.swift` (47 cases).

Modified: `AtelierRefs/AtelierRefsApp.swift` — ONE additive line, an
`@NSApplicationDelegateAdaptor(GridBakeoffAppDelegate.self)`. It is inert
without the launch argument and is the spike's only footprint outside `Debug/`.

## Notes

- `swiftUIWindowed` is a faithful RECONSTRUCTION, not the literal production
  view: `CollectionView.masonryWindow` / `masonryCell` are private and closed
  over `model` / `hoveredItemID` / a `ScrollViewProxy`. It reuses the real
  `MasonryLayoutCache`, `gridWindow`, `masonryVisibleIndices`, `windowedCells`
  and `CollectionCell`, and attaches the same wrapper chain under `.full`.
  Making the production view literally reusable would need `masonryWindow`
  extracted into a standalone view taking values rather than reading `model` —
  an invasive edit to a file another agent owns, deliberately not made.
- The window owns its OWN `IngestionModel`, so a measurement can never mutate
  the running app's loaded collection. Pair `-grid-bakeoff` with `-library-root`
  for a throwaway 2000-item library.
- Runs must be RELEASE builds (037 §3.1). A Debug build shows an unmissable
  banner and stamps every exported result, because unoptimised SwiftUI would
  unfairly damn SwiftUI — the most likely route to a wrong decision.

## Migration notes

None — additive, inert without the launch argument. Delete `Debug/` plus the one
line in `AtelierRefsApp.swift` to remove the spike; keep
`frameTimeStatistics` + its tests if frame-time measurement is wanted again.

# 189 — Retire the Debug SwiftUI bake-off modes + delete the now-dead grid code

The A4 follow-up tracked in `036 §2 A4` "As built" block. Workstreams A/B/C
shipped the AppKit `NSCollectionView` grid as default and A4 (`3da565a`) deleted
the SwiftUI grid *rendering* path — but several files could not be deleted then
because the Debug bake-off harness's two SwiftUI modes still referenced them, and
that harness compiles unconditionally (no `#if DEBUG`). This retires those two
SwiftUI modes and deletes the code they were keeping alive.

## Retired: the two Debug SwiftUI bake-off modes

- Deleted `Debug/SwiftUIWindowedBakeoffGrid.swift` and
  `Debug/SwiftUIEquatableBakeoffGrid.swift` (the `swiftUIWindowed` /
  `swiftUIEquatable` modes, and every helper defined in them:
  `BakeoffSelection`, `BakeoffCellInputs`, `BakeoffCellFidelity`,
  `BakeoffMarqueeSpace`, `BakeoffHoverSink`, `MasonryCellView`,
  `BakeoffModePlaceholder`).
- Collapsed `GridBakeoffMode` to the single `case appKit` (kept
  `CaseIterable`/`Codable`), updated its doc + the "entry points" comment block
  (`GridBakeoffSeam.swift`).
- `GridBakeoffWindow.swift`: default mode `.swiftUIWindowed` → `.appKit` (both
  the `@State` and the `init` seed); the grid-pane `switch` now has the one
  `.appKit` arm.
- `BakeoffScrollDriver.swift`: removed `SwiftUIScrollPositionTarget` (used only
  by the two SwiftUI modes). `BakeoffScrollTarget` protocol and
  `NSScrollViewBakeoffTarget` (the AppKit conformance) kept.
- `BakeoffAutorun.swift`: no change needed — it references the enum generically
  (`GridBakeoffMode(rawValue:)`, `allCases`), which still compiles.

## Kept (the AppKit bake-off mode stays as the scroll-perf regression guard)

`AppKitBakeoffGrid.swift`, `FrameTimeRecorder.swift`, `BakeoffScrollDriver.swift`,
`GridBakeoffSeam.swift`, `GridBakeoffWindow.swift`, `BakeoffAutorun.swift`. The
`appKit` mode still builds and runs; it uses `MasonryLayoutCache`,
`MasonryFrames`, and `masonryMarqueeIndices` (from `MarqueeMath.swift`) — none of
the deleted windowing code.

**`GridBakeoffWrapperConfig` (`full`/`stripped`) was KEPT.** Only the SwiftUI
modes ever *honoured* it, but it is not dead code: it is still constructed and
flows into the exported provenance envelope (`GridBakeoffResult`,
`BakeoffAutorunExport`, the autorun `wrappers=` field, the picker). Removing it
would be a cross-file refactor of kept export/provenance scaffolding and a schema
change — out of scope for a deletion pass. The AppKit mode ignores it by
specification, so it is harmless (always `.full`).

## Deleted production files/symbols (zero live non-comment references)

- `CollectionCell.swift` — `CollectionCell` + `PressReportingButtonStyle` (built
  only by the two SwiftUI modes). Its equatable test file
  `MasonryCellEquatableTests.swift` deleted with it.
- `GridWindowing.swift` (whole file) — `GridWindow`, `gridWindow`,
  `masonryVisibleIndices`, `masonryPrefetchIndices`, `windowedCells`,
  `WindowedCell`, `hoverAfterWindowChange`. Confirmed the AppKit bake-off path
  does NOT use any of it (`masonryMarqueeIndices`, which it does use, lives in
  `MarqueeMath.swift`). The live grid host uses `NSCollectionViewPrefetching`,
  not `masonryPrefetchIndices`.
- `GridMarquee.swift` — deleted the dead SwiftUI layers `GridMarqueeState`,
  `MarqueeCaptureLayer`, `MarqueeRectangleLayer`, and `DisplayLinkHost`.
  **`DisplayLinkPump` KEPT** — the live AppKit marquee auto-scroll
  (`GridMarqueeController`) sets `pump.hostView = collectionView` and steps it.
- `GridContextMenu.swift` — deleted the SwiftUI `GridContextMenuState` and
  `GridContextHighlightLayer`. **Pure functions KEPT**: `gridActionTargets`
  (called by `IngestionModel.actionTargets`), plus `masonryContextTargetIndex`
  and `gridCursorContentPoint` (unit-tested scope/hit-test rules the native
  `menu(for:)` shares). `GridContextMenuTests` untouched.

## Test surgery (not a blind delete)

`GridWindowingTests.swift` mixed the dead windowing suites with a **live**
`GifCoordinatorTests` suite — `GifAnimationCoordinator` is production code used by
the AppKit `MasonryGridItem`. So that suite was extracted to a new
`GifAnimationCoordinatorTests.swift`, and the rest of the file deleted.

## Verification

- Release build: `xcodebuild build -configuration Release` exit 0. No new
  warnings (the pre-existing Swift 6 concurrency / unused-`try?` warnings in
  `IngestionModel`/`ContentView`/`SnapshotManager`/`BakeoffScrollDriver.run`
  are untouched code).
- `AtelierRefsTests` (`-parallel-testing-enabled NO`): **467 → 425 tests**
  (−42), **78 → 71 suites** (−7). TEST SUCCEEDED, 0 failures.
- The 7 dropped suites are exactly the dead ones: `GridWindow: quantization`,
  `masonryVisibleIndices: visibility`, `masonryPrefetchIndices: the ring beyond
  the window`, `windowedCells: identity mapping`, `hover reconciliation on window
  change`, `MasonryCellView: == covers every appearance-affecting input`,
  `Bake-off fidelity fixtures are deterministic and identical across modes`. No
  other suite regressed; `GifCoordinatorTests` still present.
- Grep confirmed zero remaining non-comment references to every deleted symbol.
  Remaining references are provenance comments only (and `BakeoffDisplayLinkHost`,
  a distinct kept type in `FrameTimeRecorder.swift`).

## Migration notes

None. `AtelierUseAppKitGrid` remains a reserved (unused) UserDefaults key from
A4; nothing here touches it. The bake-off is still launched by `-grid-bakeoff`
and now only offers the `appKit` mode.

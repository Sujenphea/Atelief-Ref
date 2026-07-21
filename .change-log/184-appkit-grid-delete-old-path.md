# 184 — Delete the old SwiftUI grid path (036 §4 A4, deletion half)

## Summary

AppKit `NSCollectionView` is the default collection grid (`AtelierUseAppKitGrid`
defaulted `true` in `f66cff3`) and soak-tested at parity. This commit deletes the
now-dead old SwiftUI windowed grid *rendering path* from `CollectionView` and
collapses the feature-flag conditional so the AppKit host is unconditional. One
isolated, revert-able commit — deletion only, no behavior change.

**Key deviation from the plan:** §4 A4 also called for deleting
`GridWindowing.swift`, the SwiftUI marquee layers (`MarqueeCaptureLayer`,
`MarqueeRectangleLayer`, `DisplayLinkHost`, `GridMarqueeState`),
`PressReportingButtonStyle`, and `GridWindowingTests.swift`. **None of those were
deleted** — every one is still referenced by the `Debug/` bake-off harness (the
byte-identical regression guard, explicitly on the KEEP list / do-not-touch), so
deleting them would break the build. Per the A4 stop-rule ("if any of those
symbols are still referenced anywhere live, STOP rather than delete"), they are
kept and documented here.

## Deleted (production old-grid path in `CollectionView.swift`)

Private members reachable only from the dead `else` branch (`loadedGrid`):

- `loadedGrid(geo:)` — the whole SwiftUI windowed grid body (ScrollView +
  MarqueeCaptureLayer + windowed cells + container context menu + the
  `.focusable()`/`.onKeyPress`/`.onDeleteCommand` key-press chain).
- `masonryWindow(cells:proxy:)`, `masonryCell(_:frame:proxy:)`,
  `selectionCircle(for:)` — the old SwiftUI cell tree.
- `prefetchThumbnails(cells:layout:queryRect:viewportHeight:)` — the band-seam
  SwiftUI prefetch driver (the AppKit path uses `NSCollectionViewPrefetching`).
- C4 SwiftUI container-context-menu helpers: `containerMenu(layout:)`,
  `contextTargetIndex(layout:)`, `cellMenu(for:)`, `targetButtons(_:action:)`,
  `countSuffix(_:)` (the AppKit path uses a native `NSMenu` via `menu(for:)`).
- Selection input routing helpers: `handleImagePress`, `handleImageClick`,
  `handleArrow`, `execute(_:proxy:)` (AppKit routes mouse/keyboard through the
  coordinator + the pure `gridPressRouting`/`gridClickAction` tables).
- Private `dragPayload(for:)` (the AppKit path calls `model.dragPayload` directly).
- State backing only the old path: `marquee` (`GridMarqueeState`), `gridScroll`
  (`ScrollPosition`), `hoveredItemID`, `contextMenu` (`GridContextMenuState`),
  `masonryCache` (`MasonryLayoutCache`), `window` (`GridWindow`),
  `thumbnailPrefetcher` (`ThumbnailWindowPrefetcher`), and the `marqueeSpace`
  coordinate-space constant.
- `@AppStorage("AtelierUseAppKitGrid")` read + the `if useAppKitGrid { … } else
  { loadedGrid(…) }` conditional → collapsed to an unconditional `appKitGrid(geo:)`.

### `SettingsView.swift`

- Removed the "Experimental ▸ AppKit collection grid" toggle (`experimentalSection`)
  and its `@AppStorage("AtelierUseAppKitGrid")`.

## Kept deliberately (delete-list items still referenced by live code)

- **`GridWindowing.swift` (entire file)** — `gridWindow`, `masonryVisibleIndices`,
  `windowedCells`, `hoverAfterWindowChange`, `GridWindow`, `WindowedCell` are used
  by `Debug/SwiftUIWindowedBakeoffGrid.swift` and
  `Debug/SwiftUIEquatableBakeoffGrid.swift`. (`masonryPrefetchIndices` is no longer
  used in production but remains covered by tests.)
- **`GridMarquee.swift` marquee layers** — `MarqueeCaptureLayer`,
  `MarqueeRectangleLayer`, `DisplayLinkHost`, `GridMarqueeState` are used by the
  same two Debug grids. (`DisplayLinkPump` was always on the KEEP list — the AppKit
  `GridMarqueeController` reuses it.)
- **`PressReportingButtonStyle` (`CollectionCell.swift`)** — `CollectionCell`
  itself is instantiated by the Debug bake-off grids, and it uses this style.
- **`GridWindowingTests.swift` (entire file)** — tests the still-live
  `GridWindowing` functions above, plus `GifCoordinatorTests` covers the live
  `GifAnimationCoordinator` (ported into `MasonryGridItem` in A3).
- **`AssetContentThumbnail`, `MasonryLayout`/`MasonryLayoutCache`,
  `masonryMarqueeIndices`, `GridSelection`, `GridNavigation`,
  `gridPressRouting`/`gridClickAction`, `AssetDragPayload`** — all on the KEEP list,
  untouched.
- **`GridContextMenu.swift`** (C4 pure helpers `masonryContextTargetIndex`,
  `gridCursorContentPoint` + `GridContextMenuState`/`GridContextHighlightLayer`) —
  not on the A4 delete list; the pure functions remain covered by
  `GridContextMenuTests`. The two view/state types are no longer instantiated in
  production but compile cleanly (no warning) and were left in place as out of
  scope for this deletion.

## Feature-flag decision

Chose **(b) remove the toggle from Settings, keep the UserDefaults key reserved**
over keeping a no-op toggle. Rationale: with `loadedGrid` gone, `CollectionView`
no longer reads the flag at all — the AppKit host is unconditional — so a stale
`false` in a user's UserDefaults has no `else` branch to resurrect (verified: the
conditional and the `@AppStorage` read are both removed). A toggle whose own
help text promised "Off restores today's behavior exactly" would now be a lie and
confuse users, so removing it is lower-risk than a no-op toggle. The stored key is
untouched (no UserDefaults migration). Rollback is a clean `git revert` (restores
the toggle wired back to a restored `loadedGrid`).

## Verification

- Release build: `xcodebuild … -configuration Release` exit status **0**. No new
  warnings (all 15 remaining warnings pre-exist in `Debug/`, `ContentView`,
  `IngestionModel`, `SnapshotManager` — none in the edited files).
- `-only-testing:AtelierRefsTests -parallel-testing-enabled NO`: **428 tests in 70
  suites passed, 0 failed** (exit 0).
- **Test count before == after (428).** No test files were deleted, because
  `GridWindowingTests.swift` (26 tests) stays live — the plan's expectation that
  it "dies with the windowing code in A4" does not hold while the Debug harness
  still exercises `GridWindowing`.
- Grep-confirmed zero live references to each deleted production symbol.

## Amends to `.docs/036`

§4 A4's flat delete of `GridWindowing.swift`, the SwiftUI marquee layers,
`PressReportingButtonStyle`, and `GridWindowingTests` is **blocked by the Debug
bake-off harness**, which §5's gate deliberately keeps as a regression guard.
Those files can only be deleted once the `Debug/` SwiftUI bake-off modes
(`SwiftUIWindowedBakeoffGrid`, `SwiftUIEquatableBakeoffGrid`) and `CollectionCell`
are themselves retired — a separate step. Until then, A4's deletion is limited to
the production `CollectionView` path.

## Migration notes

None. No public API, storage, or behavior change. The `AtelierUseAppKitGrid`
UserDefaults key is now ignored (reserved, not migrated).

# 285 — Test-target warning sweep (MainActor-by-default, round two)

## Summary

283 cleared the app target's warnings; building the TEST target surfaced the
next ring of MainActor-by-default fallout, plus a handful of straight test-code
warnings. All of them are gone; a clean `build-for-testing` is warning-free.

**`nonisolated` on the pure value types tests compare.** Swift Testing's
`#expect(a == b)` evaluates its operands in a nonisolated macro expansion, so an
`Equatable`/`Hashable` conformance inferred `@MainActor` warns in every test
that compares the type — even inside a `@MainActor` suite. The 18 flagged types
are all pure data (reducer outputs, drop routes, payloads, layout structs) and
are now `nonisolated`: `GridSelection`, `GridSelectionEffect`,
`GridSelectionAction`, `GridPressRouting`, `GridArrowKey`, `GridApplyStrategy`,
`GridKeyCommand`, `DropOutcome`, `CollectionDrop`, `CanvasDropRoute`,
`AssetPasteboardEntry`, `AssetExportItem`, `AppRoute`, `SidebarItem`,
`FrameTimeStats`, `SpaceDragPayload`, `SpaceDrop`, `SpaceBarMode`,
`PlacedRect`, `TextPalette`. Their off-main dependencies came along:
`ElementRendering.rgba(fromHex:)`, `Color.init(rgba:)`, `UTType.spaceID`, and
the file-level `frameBudget60Ms`.

**`@MainActor` on the AppKit-facing test suites.** The file-promise delegate
and `dragProvider` suites exercise `NSFilePromiseProviderDelegate` /
`NSItemProvider` — main-actor machinery by design — so the suites are annotated
rather than the app types loosened: `AssetFilePromiseDelegateTests`,
`AssetFilePromiseProviderTests`, `AssetDragPayloadDragPasteboardTests`,
`AssetExportDragProviderTests`.

**Test-code cleanups.**
- `try` removed where the `rethrows` fixture closure no longer throws
  (`ContactSheetExportTests` ×5, `AssetPasteboardTests` ×5 with their outer
  nesting levels, `MoodboardExportTests` ×1).
- `let q = try? #require(x)` is just `let q = x` — the macro's own diagnostic
  says so (`LibrarySearchModelTests` ×4).
- `#expect(Thread.isMainThread)` in an async test became
  `dispatchPrecondition(condition: .onQueue(.main))` — `isMainThread` is
  unavailable from async contexts (`ThumbnailPipelineTests`).

## Files changed

- App: `GridSelection.swift`, `GridNavigation.swift`, `MasonryGridHost.swift`,
  `DropRouter.swift`, `CollectionDragPayload.swift`, `CanvasDropRouter.swift`,
  `AssetPasteboard.swift`, `AssetExport.swift`, `NavModel.swift`,
  `SpaceDragPayload.swift`, `SpaceView.swift`, `SpaceLayout.swift`,
  `SpaceFormatChrome.swift`, `ElementRendering.swift`,
  `Debug/FrameTimeRecorder.swift` — `nonisolated`.
- Tests: `AssetFilePromiseTests.swift`, `AssetExportTests.swift` —
  `@MainActor` suites; `ContactSheetExportTests.swift`,
  `AssetPasteboardTests.swift`, `MoodboardExportTests.swift`,
  `LibrarySearchModelTests.swift`, `ThumbnailPipelineTests.swift` — cleanups.

## Migration notes

- No behaviour change. The `nonisolated` types hold only Sendable value state;
  marking them nonisolated is a statement of fact the default isolation was
  hiding, and it is what lets their conformances be used from Swift Testing's
  macro expansions and any future off-main code.
- The rule of thumb from 283 extends to tests: a pure value type that tests
  compare with `#expect` must be `nonisolated` — a `@MainActor` suite does NOT
  rescue an isolated conformance, because the macro's checking closure is
  nonisolated either way.

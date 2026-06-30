# 001 — Canvas spike: package scaffold

**Checkpoint 1** of the Phase 1 canvas rendering spike (see
`.docs/004-foundation-plan.md` and the approved plan
`.claude/plans/look-into-docs-i-glittery-wren.md`).

## Summary

Created the local Swift Package `CanvasRenderer` (decision **A3**) and wired it
into the `AtelierRefs` Xcode project as a local package dependency. The package
is intentionally standalone (zero app dependency) so the renderer's view-agnostic
boundary is compiler-enforced and the spike's tests + benchmark run via
`swift test`.

This checkpoint is skeleton-only: a placeholder `CanvasRenderer` enum and a
Swift Testing smoke test that the package builds and the test harness runs. Real
types land in later checkpoints.

## Decisions realized

- **A3** — renderer lives in its own local Swift Package.
- Swift tools 6.0, Swift 6 language mode, `macOS .v14` platform floor.

## Files changed

- `CanvasRenderer/Package.swift` *(new)* — package manifest: one library target
  (`CanvasRenderer`) + one test target (`CanvasRendererTests`).
- `CanvasRenderer/Sources/CanvasRenderer/CanvasRenderer.swift` *(new)* —
  placeholder `CanvasRenderer.Backend` (`coreAnimation` | `metal`); spike starts
  on `coreAnimation` (decision A1).
- `CanvasRenderer/Tests/CanvasRendererTests/PackageSmokeTests.swift` *(new)* —
  Swift Testing smoke test.
- `AtelierRefs/AtelierRefs.xcodeproj/project.pbxproj` *(modified)* — added
  `XCLocalSwiftPackageReference` → `../CanvasRenderer`, an
  `XCSwiftPackageProductDependency`, the `packageReferences` /
  `packageProductDependencies` entries, and a `PBXBuildFile` linking the product
  into the app target's Frameworks phase.
- `.gitignore` *(modified)* — added Xcode (`*.xcuserstate`, `xcuserdata/`,
  `DerivedData/`) and SwiftPM (`.build/`, `.swiftpm/`, `Package.resolved`)
  ignores.

## Verification

- `swift test` in `CanvasRenderer/` — builds, smoke test passes.
- `xcodebuild -list` — resolves `CanvasRenderer @ local`, `CanvasRenderer` scheme
  present.
- `xcodebuild build -scheme AtelierRefs` — **BUILD SUCCEEDED**; app links the
  package.

## Migration notes

None — additive. The `CanvasRenderer` product is now importable from the app
target (`import CanvasRenderer`), but nothing imports it yet.

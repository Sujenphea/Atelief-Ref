# 009 — Data core: package scaffold + GRDB wiring

**Chunk 1** of the data-core build: scaffold the `AtelierCore` package, wire in
GRDB, and wire the package into the `AtelierRefs` Xcode app. Skeleton-only —
proves the package builds, GRDB links, and the app still builds. No domain
models yet.

## Summary

Created the local Swift Package `AtelierCore` (mirroring the `CanvasRenderer`
conventions) as the app's metadata-store boundary. GRDB (SQLite toolkit) is a
dependency of this package only, so the compiler keeps GRDB confined inside
`AtelierCore` and out of the app target.

This checkpoint is skeleton-only: a placeholder `AtelierCore` namespace plus a
tiny internal function that opens an in-memory GRDB `DatabaseQueue` and reads
`PRAGMA user_version` (forcing the linker to resolve GRDB), and a Swift Testing
smoke test that exercises it. Real schema, records, and store API land later.

## Decisions realized

- `AtelierCore` lives in its own local Swift Package; GRDB confined inside it.
- Swift tools 6.0, Swift 6 language mode, `macOS .v14` platform floor.
- GRDB `from: "7.0.0"` resolved to **7.11.1**.

## Files changed

- `AtelierCore/Package.swift` *(new)* — manifest: GRDB dependency
  (`from: "7.0.0"`), one library/target `AtelierCore` depending on
  `.product(name: "GRDB", package: "GRDB.swift")`, one test target
  `AtelierCoreTests`.
- `AtelierCore/Sources/AtelierCore/AtelierCore.swift` *(new)* — `AtelierCore`
  namespace: `databaseFileName = "library.sqlite"` + internal
  `probeUserVersion()` that opens an in-memory `DatabaseQueue` and reads
  `PRAGMA user_version`. `import GRDB`.
- `AtelierCore/Tests/AtelierCoreTests/PackageSmokeTests.swift` *(new)* — Swift
  Testing smoke test asserting the filename and that GRDB links / opens
  (`user_version == 0`).
- `AtelierRefs/AtelierRefs.xcodeproj/project.pbxproj` *(modified)* — added
  `XCLocalSwiftPackageReference` → `../AtelierCore`
  (`DA0000000000000000000001`), an `XCSwiftPackageProductDependency`
  (`DA0000000000000000000002`), the `packageReferences` /
  `packageProductDependencies` entries, and a `PBXBuildFile`
  (`DA0000000000000000000003`) linking the product into the app target's
  Frameworks phase. New unique `DA…` IDs, distinct from CanvasRenderer's `CA…`.

## Verification

- `swift test` in `AtelierCore/` — resolves GRDB 7.11.1, builds, 2 smoke tests
  pass.
- `plutil -lint project.pbxproj` — OK.
- `xcodebuild -list` / `-resolvePackageDependencies` — resolves
  `AtelierCore @ local` and `GRDB @ 7.11.1`; `AtelierCore` scheme present.
- `xcodebuild build -scheme AtelierRefs -destination 'platform=macOS'` —
  **BUILD SUCCEEDED**.

## Migration notes

None — additive. The `AtelierCore` product is now importable from the app target
(`import AtelierCore`), but nothing imports it yet. GRDB is a transitive
dependency confined to the package.

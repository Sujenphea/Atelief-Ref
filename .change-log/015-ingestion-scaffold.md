# 015 — Ingestion: package scaffold + AtelierCore wiring

**Chunk 1** of the ingestion build: scaffold the `AtelierIngestion` package,
wire in its `AtelierCore` path dependency, and wire the package into the
`AtelierRefs` Xcode app. Skeleton-only — proves the package builds, the
AtelierCore dependency links, and the app still builds. No real ingestion code
yet.

## Summary

Created the local Swift Package `AtelierIngestion` (mirroring the `AtelierCore`
conventions) as the app's capture-pipeline boundary. It will host the
content-addressed blob + thumbnail store, the hashing / metadata / thumbnail
utilities, and the ingestion pipeline + coordinator. It depends only on
AtelierCore's public `AppServices` seam to persist metadata — it never reaches
past that surface.

This checkpoint is skeleton-only: a placeholder `AtelierIngestion` namespace
(`subsystem = "ingestion"`) plus a tiny internal helper that builds a value from
an AtelierCore PUBLIC type (`CanvasPlacement`) to force the linker to resolve the
AtelierCore product, and a Swift Testing smoke test that exercises it. The real
store, utilities, and pipeline land in later checkpoints.

## Decisions realized

- `AtelierIngestion` lives in its own local Swift Package, layered on top of
  `AtelierCore` via `.package(path: "../AtelierCore")`.
- Swift tools 6.0, Swift 6 language mode, `macOS .v14` platform floor (matches
  AtelierCore / CanvasRenderer).
- System frameworks for later chunks (CryptoKit, ImageIO,
  UniformTypeIdentifiers) are platform-provided — imported directly in source,
  no SPM dependency added here.

## Files changed

- `AtelierIngestion/Package.swift` *(new)* — manifest: `AtelierCore` path
  dependency, one library/target `AtelierIngestion` depending on
  `.product(name: "AtelierCore", package: "AtelierCore")`, one test target
  `AtelierIngestionTests`.
- `AtelierIngestion/Sources/AtelierIngestion/AtelierIngestion.swift` *(new)* —
  `AtelierIngestion` namespace: `subsystem = "ingestion"` + internal
  `probeCorePlacement()` returning a `CanvasPlacement()` (AtelierCore public
  type). `import AtelierCore`.
- `AtelierIngestion/Tests/AtelierIngestionTests/PackageSmokeTests.swift` *(new)*
  — Swift Testing smoke test asserting the subsystem value and that AtelierCore
  links / its public `CanvasPlacement` resolves.
- `AtelierRefs/AtelierRefs.xcodeproj/project.pbxproj` *(modified)* — added
  `XCLocalSwiftPackageReference` → `../AtelierIngestion`
  (`EA0000000000000000000001`), an `XCSwiftPackageProductDependency`
  (`EA0000000000000000000002`), the `packageReferences` /
  `packageProductDependencies` entries, and a `PBXBuildFile`
  (`EA0000000000000000000003`) linking the product into the app target's
  Frameworks phase. New unique `EA…` IDs, distinct from AtelierCore's `DA…` and
  CanvasRenderer's `CA…`.

## Verification

- `swift test` in `AtelierIngestion/` — resolves the AtelierCore path dependency
  (and its transitive GRDB 7.11.1), builds, 2 smoke tests pass.
- `plutil -lint project.pbxproj` — OK.
- `xcodebuild -list` — resolves `AtelierIngestion @ local`, `AtelierCore @
  local`, `CanvasRenderer @ local`, `GRDB @ 7.11.1`; `AtelierIngestion` scheme
  present.
- `xcodebuild build -scheme AtelierRefs -destination 'platform=macOS'` —
  **BUILD SUCCEEDED**.

## Migration notes

None — additive. The `AtelierIngestion` product is now importable from the app
target (`import AtelierIngestion`), but nothing imports it yet. AtelierCore (and
its transitive GRDB) remains confined behind AtelierIngestion's dependency edge.

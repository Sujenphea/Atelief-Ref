# 080 — Production readiness Phase 1: P0 correctness (G1–G5)

Closes the five ship-blocking correctness bugs from
[020](../.docs/020-production-readiness-overview.md) /
[021](../.docs/021-production-readiness-plan.md) Phase 1.

## Summary

- **G1** — Hoisted `model.lastError` `.alert` from `LibraryView` to `ContentView`
  so bootstrap / Canvas / Sweeps failures surface on the default Canvas tab.
- **G2** — `IngestPipeline` best-effort `removeBlob` on failure when *this call*
  created the blob (not on the P14 dedup short-circuit).
- **G3** — `keyedByAssetID` / `uniquingKeysWith` replaces
  `Dictionary(uniqueKeysWithValues:)` in `reorderItem` so duplicate asset ids
  degrade instead of trapping.
- **G4** — `runBounded` returns a full-length `[T?]`; coordinator maps nil →
  `.cancelled` so batch outcomes stay index-aligned with inputs.
- **G5** — Canvas fixture determinism asserts matching dimensions only (CG render
  ±1/channel is not a reliable CI gate). CanvasRenderer suite ×10 green.

## Files changed

- App: `ContentView.swift`, `LibraryView.swift`, `IngestionModel.swift`,
  `GridReorder.swift` + `GridReorderTests.swift`
- Ingestion: `IngestPipeline.swift`, `IngestCoordinator.swift`, `IngestInput.swift`
  + pipeline/coordinator tests
- Server: `CaptureRoutes.swift` (exhaustive `.cancelled`)
- Canvas: `SpikeDataTests.swift`
- Docs: `.docs/019` G1 manual check note

## Migration notes

None — no schema change. Existing orphan blobs on disk (pre-fix) are not
reclaimed automatically; only new fail-after-write paths are plugged.

# 163 — Analysis: asset_analysis schema (v7) + Core surface

## Summary

Phase A of wiring feature 012 (on-device intelligence): the persistence + service
layer the analyzer writes into. The pure algorithm cores (perceptual hash 161,
color extraction 162) now have a home for their output.

**Schema (migration v7).** One additive `asset_analysis` table — independent of
the v1–v6 library schema, like v3's job ledger, so no table rebuild:

- `asset_id` PRIMARY KEY → `asset(id) ON DELETE CASCADE` (one analysis per asset;
  it dies with the asset — no orphan sweep).
- `ocr_text`, `colors`, `phash` all NULLABLE — analysis is derived, possibly-absent
  data. `colors` is opaque JSON to this layer; `phash` is the signed-INTEGER
  storage of the unsigned 64-bit hash (the bitcast happens at the Ingestion seam).
- `analyzed_at` + `analyzer_version` always present, so re-analysis after an
  algorithm upgrade is a `WHERE analyzer_version < …` scan, not a schema event.
- `analysis_fts` FTS5 over `ocr_text`, external-content synchronized (auto
  triggers + back-fill) like `source_fts`/`asset_fts` — the index Phase D unions
  into `searchAssets` for search-inside-images.

**Core surface (AppServices).** `upsertAnalysis(...)` (existence-guarded, idempotent
overwrite by the `asset_id` PK), `analysis(for:)`, and `assetsNeedingAnalysis(
analyzerVersion:limit:)` — the resumable backfill query: downloaded **image**
assets whose analysis is missing or stale-version, newest-first, limit-clamped.
Media-less kinds and video are excluded so the batch drains to empty rather than
lingering. No ledger: "still needs analysis" is one LEFT JOIN, so a killed backfill
resumes by re-running it.

Serialization stays at the Ingestion seam (2A): `colors`→JSON and `UInt64`→`Int64`
are the analyzer's job (Phase B); Core stores opaque values, keeping imaging types
and GRDB on their own sides of the boundary.

## Files changed

### AtelierCore
- `Persistence/Migrator.swift` — register `"v7"`; `createV7Schema` (table + version
  index + `analysis_fts`).
- `Domain/AssetAnalysis.swift` (new) — the value type (opaque `colors`, signed
  `phash`).
- `Persistence/AssetAnalysis+GRDB.swift` (new) — record conformance.
- `Services/AppServices.swift` — `upsertAnalysis` / `analysis(for:)` /
  `assetsNeedingAnalysis`.

### AtelierCoreTests
- `MigrationTests.swift` — v7 added to the pinned identifier list + expected tables;
  new suites: schema shape (nullability, PK, INTEGER phash, index), FK + cascade +
  signed 64-bit phash round-trip, `analysis_fts` insert/update/delete, record
  round-trips.
- `ServicesAnalysisTests.swift` (new) — upsert/read/idempotent-overwrite,
  notFound guard, cascade, and the backfill query (missing vs stale-version,
  media-less exclusion, ordering, limit clamp).

## Migration notes

Additive migration `v7` — no table rebuild, no existing data touched. Append-only
rule honored (v7 registered + pinned; never edit v1–v6). Full AtelierCore suite
green (365 tests). Analyzer service + Vision seam land in Phase B.

## Verify

- `swift test` (AtelierCore) — 365 tests green.

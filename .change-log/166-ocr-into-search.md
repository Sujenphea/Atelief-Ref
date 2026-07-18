# 166 — Analysis: OCR text into the search union

## Summary

Phase D (final wiring phase) of feature 012: text recognized inside images is now
searchable. `searchAssets` gains a third FTS `MATCH` arm over `analysis_fts`
(012's OCR index, populated by the backfill), OR-combined with the existing
provenance (`source_fts`) and content (`asset_fts`) arms.

An asset now matches a text query when the token appears in its provenance
(title/author) OR its own content (a tweet's text, a link's title, a color's name)
OR **the text inside the image** (a screenshot's UI copy, a type specimen's
lettering). This is 012's "highest search-quality win": design refs are mostly
images, and their most searchable substance — the words rendered in them — was
previously invisible to search.

The three external-content indices stay separate (provenance vs content vs derived
OCR) and are unioned only at query time, so analysis writes never touch the
content FTS, and OCR search updates automatically as the backfill re-indexes
(external-content triggers on `asset_analysis`).

## Files changed

### AtelierCore
- `Services/AppServices.swift` — `searchAssets` adds the `analysis_fts` OR arm
  (third `match` argument); comment updated to describe the three-way union.

### AtelierCoreTests
- `ServicesAnalysisTests.swift` — OCR-search tests: a token found only in OCR
  matches; an un-analyzed image is not matched by an OCR-only token; re-analysis
  overwriting the OCR text re-indexes (old token stops matching, new token starts).

## Migration notes

None — query-only change over the `analysis_fts` table from migration v7 (163).
Full AtelierCore suite green (368 tests).

**Feature 012 wiring (Phases A–D) is complete at the package level:** schema +
service surface (163), analyzer + Vision seam (164), backfill orchestration (165),
and OCR search (this). Remaining 012 work is app-side and deferred: the detail
swatch row, the duplicates review surface (near-dup via phash + color
disambiguation), the search-by-color filter, the idle-priority backfill scheduler,
and the video / suggested-tags follow-ons.

## Verify

- `swift test` (AtelierCore) — 368 tests green.

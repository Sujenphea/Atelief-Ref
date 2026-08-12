# 012 — On-Device Intelligence: OCR Search, Suggested Tags, Color, Near-Duplicates

> The library's passive-metadata layer, all local (Vision/ImageIO — no network, no
> cloud ML; fits the app's posture exactly). Settled posture (user, 2026-07-13):
> machine tags **suggest, never self-apply** — the user confirms. OCR text and
> color data are passive indexes and need no confirmation.

## Status (re-verified against the tree 2026-08-12)

**All six phases have shipped.** I3 landed 2026-08-12 (schema **v22**,
`.change-log/382`) and this doc has no live remainder. The paragraphs below about
I3 being "rendering only" are historical — kept because the correction they record
(I3 was materially larger than an accept/dismiss UI) is the reason it was
estimated properly.

| Phase | State | Where |
|---|---|---|
| I1 analyzer plumbing | **shipped** | schema **v7** `asset_analysis` (`ocr_text` / `colors` / `phash` / `analyzer_version` + its index), `AnalysisCoordinator.swift`, `AssetAnalysis.swift`, `ServicesAnalysisTests` |
| I2 OCR into search | **shipped** | `analysis_fts`, external-content synchronized with `asset_analysis` via triggers (`Migrator.swift:803-811`); scored into the search union at `AppServices.swift:2722` |
| I3 suggested tags | **shipped** | schema **v22** `tag_suppression` + `asset_analysis.suggest_version`; `TagSuggestion` / `VisionImageClassifier` / `SuggestionBackfill` (Ingestion), `acceptSuggestion` / `dismissSuggestion` / `recordSuggestions` (`AppServices`), `SuggestionChip` in the detail sidebar. `ServicesSuggestionsTests`, `MigrationV22Tests`, `TagSuggestionTests`, `SuggestionBackfillTests` |
| I4 color | **shipped** | schema **v21** `asset_color` + the search conjunct, `ColorPalette.swift` (Ingestion), the detail swatch row and the toolbar palette picker, `SearchRules` v2. Planned in [085](../085-color-filter-plan.md); shipped across `.change-log/375`–`380` |
| I5 duplicates review | **shipped** | `DuplicateReviewController.swift` + `DuplicateReviewSheet.swift`, `ServicesDuplicateHashesTests`, `DuplicateReviewControllerTests` |
| I6 feature-print similarity | **shipped early** | `AssetEmbedding` + schema **v14** dense-vector search, `ServicesEmbeddingTests`, `ServicesSemanticSearchTests`. Marked "deliberately v2" below; it landed anyway |

Live remainder: **none.**

I3 shipped as the producer plus its accept/dismiss/suppress semantics, and two of
this doc's own statements did not survive contact with the schema:

- **"one click accepts (source flips `.agent` → `.user`)" is not implementable as
  written.** `tag.source` is a column on the shared `tag` ROW, so flipping it
  would confirm the suggestion on every other asset carrying it. Accept is an
  unlink-and-re-apply, per asset (`.change-log/382` §2).
- **Suggestions could not ride `analyzer_version`.** That constant gates OCR,
  colors and the phash together, so a tag-model change would have re-OCR'd the
  library. `suggest_version` is its own column, and `upsertAnalysis` carries it
  across a re-analysis (§3).

The suppression memory — the piece this doc correctly identified as the only real
design question — is `tag_suppression`, keyed on the tag NAME rather than a
`tag.id`, because dismissing unlinks the tag and an unreferenced tag row is not
kept alive to satisfy a foreign key.

**I4 shipped 2026-08-11**, as planned in [085](../085-color-filter-plan.md): the
palette and bucket rule in Ingestion, a v21 `asset_color` table with the filter as
a WHERE conjunct, a resumable derivation pass keyed on a palette VERSION rather
than a row count, the detail swatch row, and the toolbar palette picker. Two
things the plan did not foresee, both found in use within the hour: the chroma
gate had to become hue-dependent (`.change-log/378`), and the swatch row had to
apply the search's own coverage floor or half its chips could not return the
picture they were drawn on.

**I3 is not comparable** — that claim was wrong when written (corrected
2026-08-11).
*Nothing in the tree produces an agent tag.* The only `.agent` references are the
two rendering sites that would draw a sparkle if one existed
(`ItemDetailView.swift:1915`, `LibrarySearch.swift:642`). I3 needs the suggestion
producer built before accept/dismiss/suppress has anything to act on, which makes
it materially larger than an accept/dismiss UI.

The suppression memory (a dismissed suggestion that must survive an
`analyzer_version` bump) is the only piece with a real design question left in
it, and it is the one this doc's risk list already flags.

## Current state at the time of writing (historical — see Status above)

- `TagSource.agent` has existed in the schema since v1 and is **used nowhere** —
  the data model anticipated this feature.
- Dedup is **exact-hash only** (18A): a resized/re-encoded copy of the same image
  ingests as a new asset undetected.
- FTS covers `source(title, author_handle, author_name)` only — text *inside*
  images (UI screenshots, type specimens — most design refs) is invisible to
  search. No color data of any kind.

## Architecture

A new **`AssetAnalyzer`** service (AtelierIngestion is the natural home — it owns
image decoding) + one additive table:

```sql
CREATE TABLE asset_analysis (
  asset_id TEXT PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
  ocr_text TEXT NULL, colors TEXT NULL,        -- top-5 [hex, coverage] JSON
  phash INTEGER NULL,                           -- 64-bit dHash
  analyzed_at TEXT NOT NULL, analyzer_version INTEGER NOT NULL
);
```

`analyzer_version` makes re-analysis on algorithm upgrades a WHERE clause, not a
schema event. Analysis runs post-ingest for new assets + a throttled background
backfill queue for existing ones (idle-priority, resumable — "next unanalyzed
batch" is a query, no ledger needed). Vision calls live behind an injectable
protocol so every consumer is testable without Vision.

## The four capabilities

1. **OCR → search** (`VNRecognizeTextRequest`): recognized text lands in
   `ocr_text` and joins the search union — [007] already plans `searchAssets` as
   a multi-source FTS union for [003]'s `asset_fts`; OCR is a third source (own
   small FTS table now if it ships before 003, folded into `asset_fts`'s
   `search_text` when the 003 rebuild lands — decide by actual ship order).
   Highest search-quality win in the roadmap.
2. **Suggested tags** (`VNClassifyImageRequest`, confidence-thresholded): stored
   as `asset_tag` rows with `TagSource.agent`, rendered as **dimmed suggestion
   chips** in [006]'s `ItemTagsView`; one click accepts (source flips → `user`),
   ✕ dismisses (row deleted + a small suppression memory so it doesn't
   resurrect). **Unaccepted agent tags are NOT filter targets and NOT in [007]'s
   token vocabulary** — the settled posture: the curated library never contains
   unconfirmed machine guesses.
3. **Color extraction + search-by-color**: downsample → k-means in Lab space
   (pure Swift, fixture-testable — no Vision needed) → top-5 `[hex, coverage]`.
   UI: swatch row in detail; a color filter chip (picker + distance threshold in
   Lab) as another [007] WHERE conjunct. Complements [003]'s color *kind* (saved
   swatches) — different things; the filter searches *image contents*.
4. **Near-duplicate review**: 64-bit dHash (pure, property-testable) + a
   "Duplicates" review surface listing Hamming-distance clusters. **Review-only,
   never auto-merge** — actions are look-at-both / delete-one (existing
   `deleteAssets` path). Embedding-based *similar-image* search
   (`VNGenerateImageFeaturePrint` + ANN) is deliberately v2 — storage + index
   complexity for a browse feature, after the basics prove out.

## Schema / migration impact

One additive migration (`asset_analysis` + FTS side-table if pre-003). Suggested
tags reuse `asset_tag` unchanged.

## Phased implementation

1. ~~**I1 (M)** — analyzer plumbing.~~ **Shipped** (v7).
2. ~~**I2 (S–M)** — OCR into the search union.~~ **Shipped** (`analysis_fts`).
3. ~~**I3 (M)** — the producer, then accept / dismiss / suppress.~~ **Shipped**
   (v22). The last clause — the suppression surviving a version bump — was indeed
   the whole design, and it is pinned by
   `ServicesSuggestionsTests.suppressionSurvivesVersionBump`.
4. **I4 (S–M) — color swatches + color filter conjunct.** Data is already stored;
   this is a swatch row in detail plus one WHERE conjunct in the search builder.
   Note it must land as a **conjunct**, not a post-filter, for the same paging
   reason [084](../084-archive-shelf-plan.md) settles for `archived_at`.
5. ~~**I5 (M)** — duplicates review surface.~~ **Shipped.**
6. ~~**I6 (v2)** — feature-print similarity browse.~~ **Shipped** (v14).

## Test strategy

- Pure: dHash (reflexive distance 0, resize-stability on fixtures, bit-flip
  distance), k-means determinism with seeded init, Lab distance, threshold logic,
  suppression memory, cluster grouping.
- Service: backfill resumability (kill mid-batch → next query resumes), version
  bump re-analyzes, cascade on asset delete.
- Search: OCR conjunct + union paging (extends 007's suite); accepted-vs-agent
  vocabulary exclusion.
- Vision itself: thin adapter, fixture smoke test (one known image), everything
  else mocked.

## Effort: **L** total (each phase independently S–M)

## Risks & edge cases

- Vision classification labels are generic ("poster", "text") — tune threshold
  high; suggestion UX tolerates misses far better than noise.
- Backfill on a huge library must be genuinely idle-priority (QoS + batch
  size + pause-on-user-activity) — never compete with ingest or the canvas.
- OCR on video: poster frame only in v1 (frame sampling is v2 cost).
  **Delivered 2026-08-12** (`.change-log/383`) — and cheaper than this line
  assumed: the poster is rendered at ingest and already on disk, so video
  analysis was a blob-selection change (`AnalysisSource`), not a pipeline.
  The exclusion had been costing videos their colors and, for one day, their
  suggested tags. Frame SAMPLING remains v2 and remains real.
- Dismissed-suggestion memory must survive re-analysis (`analyzer_version` bump
  must not resurrect dismissed tags).
- `asset_analysis` is derived data — excluded from [081](../081-backup-plan.md) export (recomputable),
  included in snapshots (it's in the DB anyway).

## Settled decisions

- Suggest-and-confirm posture for agent tags (user, 2026-07-13); passive indexes
  (OCR/color/phash) need no confirmation; near-dup is review-only; all inference
  on-device.

## Open questions — all closed

1. ~~Backfill trigger?~~ Automatic and idle-priority, as recommended —
   `AnalysisCoordinator` drains every pass, suggestions last and bounded.
2. ~~Color filter UI?~~ Answered by I4's toolbar palette picker.
3. ~~Suggestion cap per item?~~ **Top 3**, as recommended, gated at
   `hasMinimumRecall(0.01, forPrecision: 0.9)` (`TagSuggestion.maxSuggestions`).

One thing this doc never asked, raised by building it: suppression is per
(asset, name), so refusing a generic label like "text" is a per-item action. A
library-wide never-suggest list would be a second, coarser table — deliberately
not built, and not folded into `tag_suppression`.

# 012 — On-Device Intelligence: OCR Search, Suggested Tags, Color, Near-Duplicates

> The library's passive-metadata layer, all local (Vision/ImageIO — no network, no
> cloud ML; fits the app's posture exactly). Settled posture (user, 2026-07-13):
> machine tags **suggest, never self-apply** — the user confirms. OCR text and
> color data are passive indexes and need no confirmation.

## Status (re-verified against the tree 2026-08-10)

**Four of six phases have shipped, including the one this doc deferred to v2.**

| Phase | State | Where |
|---|---|---|
| I1 analyzer plumbing | **shipped** | schema **v7** `asset_analysis` (`ocr_text` / `colors` / `phash` / `analyzer_version` + its index), `AnalysisCoordinator.swift`, `AssetAnalysis.swift`, `ServicesAnalysisTests` |
| I2 OCR into search | **shipped** | `analysis_fts`, external-content synchronized with `asset_analysis` via triggers (`Migrator.swift:803-811`); scored into the search union at `AppServices.swift:2722` |
| I3 suggested tags | **rendering only** | agent tags render as a sparkle chip (`ItemDetailView.swift:1894`, `tag.source == .agent`). **No accept, no dismiss, no suppression memory exists** — the half that makes suggest-and-confirm real is unbuilt |
| I4 color | **computed, never surfaced** | `colors` is populated by the backfill and decodes via `ColorSwatch.decodeList`, but nothing displays a swatch row and no color filter exists. The app's `ColorSwatchTile` / `ColorSwatchWell` are the *color-kind* UI (`AddColorForm`), a different feature |
| I5 duplicates review | **shipped** | `DuplicateReviewController.swift` + `DuplicateReviewSheet.swift`, `ServicesDuplicateHashesTests`, `DuplicateReviewControllerTests` |
| I6 feature-print similarity | **shipped early** | `AssetEmbedding` + schema **v14** dense-vector search, `ServicesEmbeddingTests`, `ServicesSemanticSearchTests`. Marked "deliberately v2" below; it landed anyway |

Live remainder: **I3's accept/dismiss/suppress semantics** and **I4's swatch row
+ color filter**. Both are UI on top of data that is already being computed and
stored — no analyzer work, no schema.

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
3. **I3 (S–M now) — accept / dismiss / suppress.** The chips render already; what
   is missing is the interaction: one click accepts (source flips `.agent` →
   `.user`), ✕ dismisses (row deleted **plus** a suppression memory), and the
   suppression must survive an `analyzer_version` bump or every re-analysis
   resurrects what the user rejected. That last clause is the whole design.
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
- Dismissed-suggestion memory must survive re-analysis (`analyzer_version` bump
  must not resurrect dismissed tags).
- `asset_analysis` is derived data — excluded from [081](../081-backup-plan.md) export (recomputable),
  included in snapshots (it's in the DB anyway).

## Settled decisions

- Suggest-and-confirm posture for agent tags (user, 2026-07-13); passive indexes
  (OCR/color/phash) need no confirmation; near-dup is review-only; all inference
  on-device.

## Open questions

1. Backfill trigger: automatic on launch (recommended, idle-priority) or a
   Settings "Analyze library" button first run?
2. Color filter UI: preset palette chips (recommended v1) vs full color wheel?
3. Suggestion cap per item (recommend top 3 above threshold)?

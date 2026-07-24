# 218 — Search overhaul, Phase 3a (semantic text search)

Adds MEANING-based search — "cozy reading nook" or "brutalist architecture" finds
items by concept, not keyword — via on-device sentence embeddings + cosine kNN,
and finally WIRES the previously-dormant analysis pipeline into the app. Phase 3a
of a 3-phase roadmap (see `.docs/044-search-overhaul-research.md` /
`047-search-semantic-plan.md`); visual/CLIP search (3b) and keyword+semantic
score-fusion are out of scope here.

## What changed

- **Semantic embeddings.** New migration **v14** `asset_embedding` (one 512-d
  vector per asset, opaque BLOB) with its own `model_version` + a `content_hash`
  of the embedded text. Populated on-device by `NLEmbedding.sentenceEmbedding`
  (built-in — no model bundled).
- **Embedder + backfill (AtelierIngestion).** A `TextEmbedding` seam,
  `NLSentenceEmbedder` (L2-normalized output), `EmbeddingCorpus` (title + name +
  note + OCR, fixed order + SHA-256 hash), and `EmbeddingBackfill` (resumable
  drain of missing / model-stale / OCR-newer rows, plus an oldest-first re-verify
  that catches renames the timestamp-less `asset` can't signal — the 4A guard).
- **kNN search (AtelierCore).** `semanticSearchAssets(queryVector:modelVersion:…)`
  — structured tag / collection / platform filters run in SQL FIRST (so a nearer
  out-of-scope match never displaces a real one), then Accelerate `vDSP_dotpr`
  cosine ranking with a deterministic tiebreak. Brute-force over library-scale
  vectors; no vector DB.
- **The dormant pipeline is now wired.** A new `AnalysisCoordinator` runs a
  `.background` idle loop that drains `AnalysisBackfill` (OCR/colors/phash) THEN
  `EmbeddingBackfill` (so the semantic corpus sees fresh OCR), plus a bounded
  re-verify pass — the app's first invocation of the analysis machinery.
- **UI.** A native `.searchScopes` "Keyword / Meaning" toggle under the search
  field; Meaning embeds the query and routes to `semanticSearchAssets`, keeping
  the tag / collection scope. Keyword mode is unchanged.

## Files changed

- `AtelierCore`: `Migrator.swift` (v14), `Domain/AssetEmbedding.swift` (+`[Float]`↔
  `Data` codec), `Persistence/AssetEmbedding+GRDB.swift`, `Services/AppServices.swift`
  (`upsertEmbedding` / `embedding(for:)` / `assetsNeedingEmbedding` /
  `embeddingsToReverify` / `markEmbeddingVerified` / `semanticSearchAssets`),
  `Services/ServiceTypes.swift` (`EmbeddingCandidate`).
- `AtelierIngestion`: `Embedding/TextEmbedding.swift`, `NLSentenceEmbedder.swift`,
  `EmbeddingCorpus.swift`, `EmbeddingBackfill.swift`.
- `AtelierRefs`: `AnalysisCoordinator.swift` (new), `IngestionModel.swift`
  (bootstrap wiring), `LibrarySearch.swift` (`SearchMode`, semantic seam,
  `.searchScopes` toggle).
- Tests: `AssetEmbeddingCodecTests`, `MigrationV14Tests`, `ServicesEmbeddingTests`,
  `ServicesSemanticSearchTests` (AtelierCore); `EmbeddingCorpusTests`,
  `EmbeddingBackfillTests`, `NLSentenceEmbedderTests` (AtelierIngestion);
  `LibrarySearchModelTests` semantic-mode routing (app). `MigrationTests` pin += v14.

## Migration notes

- **v14 is additive and automatic** — it only CREATEs the derived `asset_embedding`
  table (no base table touched). Embeddings populate lazily as the coordinator
  backfills on idle; until then, Meaning mode simply returns nothing for an asset.
- **No API break.** `searchAssets` is unchanged; semantic search is a separate
  `semanticSearchAssets` method. `NLEmbedding.sentenceEmbedding` ships with the OS,
  so no model is bundled; on a device without it, Meaning mode is inert (never errors).
- **New background work:** the app now runs on-device OCR + embedding at
  `.background` priority. Resumable across launches; a true pause-on-user-activity
  gate is a later refinement.

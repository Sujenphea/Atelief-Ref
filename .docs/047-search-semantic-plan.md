# 047 — Search Overhaul: Phase 3a Plan (semantic text search)

Approved plan for Phase 3a of the search overhaul. Background / option evaluation:
`044-search-overhaul-research.md` (options F + G). Phase 1 keyword backbone: `045`;
Phase 2 trigram substring: `046`. Twelve decisions were reviewed interactively;
all resolved to the recommended option.

## Scope

Phase 3 splits into two INDEPENDENT capabilities in different embedding spaces:
- **3a (this plan)** — SEMANTIC TEXT search via `NLEmbedding.sentenceEmbedding`
  (built-in, 512-dim, no model to bundle): "brutalist architecture" matches an
  item's title / name / note / OCR by MEANING, not keywords.
- **3b (later)** — VISUAL search via MobileCLIP (bundled ~50 MB): "search by what
  the image looks like". Reuses the storage / kNN / scheduler plumbing 3a builds.

Out of scope for 3a: MobileCLIP / visual (3b); automatic keyword+semantic score
fusion (deferred — 9A); multilingual (`NLContextualEmbedding`, 1B, deferred).

## Decided design (issues 1–12)

- **1A** `NLEmbedding.sentenceEmbedding(for: .english)` — synchronous, 512-dim,
  no async asset lifecycle. (Probe: cos(modernist,brutalist)=0.58 vs
  cos(modernist,fruit)=0.16.)
- **2A** Embed title + user name + note + OCR text (the same corpus keyword search
  covers), concatenated in a fixed order, truncated to the model window.
- **3** New `asset_embedding` table (separate from `asset_analysis` — a model bump
  never re-runs OCR).
- **4A** Staleness by CONTENT HASH: store a hash of the embedded text; re-embed on
  `model_version` bump OR hash mismatch. `asset` has no `updated_at`, so detection
  is: SQL for missing / version-stale / OCR-newer (`analyzed_at > embedded_at`);
  content-hash re-verification (bounded, oldest-first) for name/note edits.
- **5A** New `TextEmbedder` (protocol `TextEmbedding` + fake) + `EmbeddingBackfill`
  orchestrator in AtelierIngestion, mirroring `AssetAnalyzer` / `AnalysisBackfill`.
- **6A** ONE app-level background coordinator, low-QoS + idle + pause-on-activity,
  draining `AnalysisBackfill` (OCR/colors/phash) THEN `EmbeddingBackfill` (so the
  corpus is complete; the content-hash re-embeds for free once late OCR lands).
- **7** New `semanticSearchAssets(...)` in `AppServices`, separate from the tested
  FTS `searchAssets` path.
- **8A** Structured filters (collection / tag / platform) run in SQL FIRST to a
  candidate id set; cosine ranks only those vectors (scoped, no recall cliff).
- **9A** Keyword and semantic stay SEPARATE for 3a (explicit mode); true bm25+cosine
  fusion deferred.
- **10A** Explicit search-field toggle (Keyword / Meaning) routing to the new method.
- **11** Load `(id, vector)` per query, cosine via Accelerate vDSP; measure before
  caching. Documented library-scale ceiling.
- **12** `TextEmbedding` protocol + deterministic fake for unit/e2e; real
  `NLSentenceEmbedder` thinly wraps NaturalLanguage; one `hasAvailableAssets`-guarded
  smoke test.

## Implementation steps

### 1. Storage — `AtelierCore`
- **Migration v14** (`Migrator.swift`): `asset_embedding` (`asset_id` PK/FK
  `ON DELETE CASCADE`, `model_version INTEGER NOT NULL`, `content_hash TEXT NOT NULL`,
  `vector BLOB NOT NULL`, `embedded_at TEXT NOT NULL`) + index on `model_version`.
  Append `"v14"` to `registeredIdentifiers` (+ test `committedIdentifiers`).
- **`AssetEmbedding`** domain model (Sendable/Codable) + `+GRDB` conformance.
- **Vector BLOB codec**: `[Float]` ↔ `Data` (512×Float32 little-endian); a helper
  with round-trip + endianness tests.
- **`AppServices`**: `upsertEmbedding(assetID:modelVersion:contentHash:vector:)`,
  `embedding(for:)`, and `assetsNeedingEmbedding(modelVersion:limit:)` (text-bearing
  candidate rows so the backfill can hash + decide), plus the vector-loading read
  for kNN (`embeddingVectors(modelVersion:candidateIDs:)`).

### 2. Embedder + backfill — `AtelierIngestion`
- Protocol `TextEmbedding { func embed(_ text: String) -> [Float]? }` + fake.
- `NLSentenceEmbedder` (real): wraps `NLEmbedding.sentenceEmbedding`, L2-normalizes
  the vector (so cosine = dot product). `static let modelVersion = 1`.
- `EmbeddingCorpus`: builds the 2A text (title+name+note+OCR, fixed order) and its
  `content_hash`. Shared so search-query embedding and asset embedding agree.
- `EmbeddingBackfill`: `assetsNeedingEmbedding` → build corpus → hash → embed stale
  → `upsertEmbedding`; batch + drain, one bad asset never aborts the batch.

### 3. Semantic query — `AtelierCore`
- `semanticSearchAssets(query:platform:tagIDs:tagMatch:collectionIDs:limit:)`:
  embed `query` (same normalize/L2 as assets) → SQL candidate id set from the
  structured filters (8A) → load candidate vectors → cosine (vDSP) → top-`limit`
  ids → fetch `AssetDetail`. Empty query → empty result (no match-everything).

### 4. Scheduler + UI — `AtelierRefs`
- `AnalysisCoordinator` (app): a low-QoS, idle-triggered, pause-on-user-activity
  Task that drains `AnalysisBackfill` then `EmbeddingBackfill`. First real wiring of
  the analysis pipeline into the app.
- `LibrarySearch.swift`: a Keyword / Meaning toggle; Meaning routes the query
  through the closure seam to `semanticSearchAssets`. Relevance/tokens/`tag:` stay
  keyword-only; the scope filters still apply in Meaning mode.

## Tests

- **Codec**: `[Float]`↔`Data` round-trip, length, little-endian byte layout, empty.
- **Migration v14**: table + index exist; FK cascade drops embeddings with the asset.
- **Corpus/hash**: fixed field order; hash changes iff text changes; OCR inclusion.
- **Backfill (fake embedder)**: never-embedded → embedded; `model_version` bump
  re-embeds; content-hash mismatch (rename / late OCR) re-embeds; unchanged → no-op;
  one failing asset doesn't abort the batch.
- **`semanticSearchAssets` (fake)**: cosine ORDER (nearest first, deterministic
  tiebreak); scope filters compose (8A — a match outside scope is excluded even if
  nearer); empty query → empty; respects `limit`.
- **Real smoke test**: guarded on `NLEmbedding.sentenceEmbedding != nil` — a
  semantically-near phrase outranks an unrelated one end-to-end.
- **`LibrarySearchModel`**: the Meaning toggle routes to the semantic seam with the
  scope filters; Keyword mode unchanged.

## Verification

1. `cd AtelierCore && swift test`; `cd AtelierIngestion && swift test`
2. `xcodebuild test -project AtelierRefs/AtelierRefs.xcodeproj -scheme AtelierRefs`
3. Manual: let the coordinator backfill; toggle Meaning; search a concept not
   present as a keyword (e.g. "mid-century furniture") and confirm relevant hits.

## Changelog

`.change-log/218-search-semantic-phase3a.md` — summary, files, migration note
(v14 `asset_embedding`: additive; embeddings populate as the coordinator backfills).

# 044 — Search Overhaul: Research

Investigation of the current search implementation, evaluation of candidate
approaches, and the recommended roadmap. Companion plan: `045-search-overhaul-plan.md`.

## Current implementation (as of 043)

Pipeline: `LibrarySearch.swift` (UI, 220ms debounce, `.searchable` token field)
→ `AppServices.searchAssets` → SQLite FTS5, three external-content indexes
OR-combined, plus a `LIKE` contains-match on tag names:

| Index | Fields |
|---|---|
| `source_fts` | source `title`, `author_handle`, `author_name` |
| `asset_fts` | `search_text` — derived once at ingest (tweet text, link title/description/host, color hex) |
| `analysis_fts` | `ocr_text` (012 analysis pass) |
| LIKE (not FTS) | tag names, contains-match |

Ordering: `created_at DESC, id DESC` only — no relevance ranking. Keyset cursor
is defined on that order. The search UI never paginates (`limit: 500`, no cursor).

### Why it feels like exact-match

`ftsMatchQuery` (AppServices) wraps every whitespace-split term in FTS5 quotes —
correct injection-proofing, but quoting neutralizes the `*` prefix operator, so
every term must match a complete word. "typo" cannot find "typography". Default
unicode61 tokenizer: case/diacritic folding only — no stemming, substrings, or
typo tolerance.

### Fields never searched

- **`asset.name` / `asset.note`** (user-given, 041): in no FTS index. `asset_fts`
  syncs only the `search_text` column, which `setName`/`setNote` never touch.
  The strongest user-supplied search signal is invisible. Biggest gap.
- **Collection names** — items are not findable by the collection they live in.
- `original_url` beyond the host (host folded into `search_text` for links only).
- `platform` is a `searchAssets` param the search-field UI never exposes.

## Options evaluated

**A. Fix FTS5 usage (incremental).** Prefix-star the trailing term (quoted-prefix
`"wo"*` stays injection-safe), BM25 relevance, index name/note/collections.
Small, contained, no new dependencies. Fixes ~80% of the pain. **→ Phase 1.**

**B. Porter stemming tokenizer.** design/designs/designing equivalence. Cheap but
English-only; doesn't address substrings or typos. Low priority, optional.

**C. Trigram tokenizer.** True substring matching ("air" finds "chair"); also
accelerates the tag LIKE. Larger index; <3-char queries need a LIKE fallback.
Best as a fourth index over short fields (title/name/author/tags), not OCR blobs.
**→ Phase 2.**

**D. True fuzzy (spellfix1 / Levenshtein).** spellfix1 is not in Apple's or
GRDB's SQLite; would require a custom SQLite build or in-app edit distance.
High complexity, marginal gain over trigram at this scale. **Rejected.**

**E. Core Spotlight (`CSSearchQuery`).** A second index to keep in sync; weaker
than FTS5 for structured filters (tags AND collection scope AND keyset paging);
can't reuse `SearchRules`. Good *additive* system-integration feature, wrong as
the in-app engine. **Deferred, optional.**

**F. Semantic text embeddings (NLContextualEmbedding).** On-device vectors +
brute-force cosine (Accelerate) — no vector DB needed at library scale. Rides
the same analyzer pipeline as G. **→ Phase 3 companion.**

**G. CLIP image embeddings (MobileCLIP).** Search by what the image *looks like*
("brutalist concrete stairs") — the transformative feature for a visual refs
app. ~50MB Core ML model, 3–15ms/inference on Apple silicon; lands in the
existing `asset_analysis` + analyzer-version backfill pattern. **→ Phase 3.**

## Recommendation (adopted)

1. **Phase 1 — keyword backbone** (A): prefix matching, relevance sort, missing
   fields, collection scope tokens, `tag:` syntax. See `045-search-overhaul-plan.md`.
2. **Phase 2 — trigram** (C) over short fields, replacing the LIKE scans.
3. **Phase 3 — MobileCLIP + text embeddings** (G + F) via `asset_analysis`.

Skip D entirely; treat E as an optional later system-integration extra.

## References

- SQLite FTS5: https://sqlite.org/fts5.html
- Trigram name-matching in FTS5: https://davidmuraya.com/blog/sqlite-fts5-trigram-name-matching/
- GRDB FTS5 tokenizers: https://github.com/groue/GRDB.swift/blob/master/Documentation/FTS5Tokenizers.md
- MobileCLIP (Apple ML Research): https://machinelearning.apple.com/research/mobileclip
- NLContextualEmbedding example: https://github.com/buh/NaturalLanguageEmbeddings

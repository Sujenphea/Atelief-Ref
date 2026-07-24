# 046 — Search Overhaul: Phase 2 Plan (trigram substring)

Approved implementation plan for Phase 2 of the search overhaul. Background and
option evaluation: `044-search-overhaul-research.md` (option C). Phase 1 (keyword
backbone) is `045-search-overhaul-plan.md`. Four design decisions were reviewed
interactively; all resolved to the recommended option.

## Context

After Phase 1, free-text search is relevance-ranked and covers the fields users
remember, but the `source_fts` / `asset_fts` / `analysis_fts` indexes use the
`unicode61` tokenizer, which matches whole WORDS only (plus a prefix on the
trailing term): "air" cannot find "chair". Tag and collection names are in no
FTS index at all — Phase 1 matched them with un-indexed leading-wildcard
`LIKE '%…%'` scans, flagged there as Phase 2's designed replacement.

Out of scope: embeddings / semantic / visual search (Phase 3 — MobileCLIP + text
embeddings), stemming (option B), spellfix1 fuzzy (option D, rejected), Core
Spotlight (option E, optional later).

## Decided design (issues 1–4)

- **1A** Four per-entity `trigram` tables mirroring the external-content pattern:
  `source_trigram`(title, author_handle, author_name), `asset_trigram`(name),
  `tag_trigram`(name), `collection_trigram`(name) — each `synchronize(withTable:)`,
  GRDB owns the triggers + back-fill. Note / OCR / search_text stay unicode61
  (trigram over long prose bloats the index for no asked-for recall).
- **2A** AUGMENT, not replace: keep `source_fts` / `asset_fts` (whole-word +
  prefix + real `bm25` relevance) and ADD trigram arms for substring recall.
- **3A** Trigram engages only for terms ≥3 chars; 1–2 char queries fall back to
  the Phase-1 unicode61 prefix/exact (+ LIKE for tag/collection). To keep the
  multi-term AND exact, the WHOLE query is trigram-eligible only when EVERY term
  is ≥3 chars (else fall back for the whole query, don't drop the short term).
- **4A** New relevance tier between word and OCR: whole-word/prefix (`bm25`,
  tier 0) > substring-only (trigram, neutral base) > OCR (`analysis_fts`).

Additional as-built rule (5A parity): a TRAILING SPACE finishes the word →
exact semantics, so it suppresses the substring arm too (not just the prefix
star). "typo " must not surface "Typography".

Tokenizer: `trigram case_sensitive 0 remove_diacritics 1` — case- and
diacritic-folded to match the unicode61 indexes ("cafe" finds "Café"). GRDB 7
has no `.trigram()` factory, so it's built via
`FTS5TokenizerDescriptor(components:)`. Verified against SQLite 3.51 before coding.

## Implementation steps

### 1. Migration v13 — `AtelierCore/.../Persistence/Migrator.swift`
Append-only migration after v12: add `"v13"` to `registeredIdentifiers`, register
the block, add `createV13Schema` creating the four trigram virtual tables (each
`t.tokenizer = trigram`, `synchronize(withTable:)`, the short columns). No base
table is touched — GRDB back-fills existing rows and regenerates triggers in one
transactional step.

### 2. Query layer — `AtelierCore/.../Services/AppServices.swift`
- New `static func trigramMatchQuery(_:) -> String?` — `nil` unless every
  whitespace term is ≥3 chars; each eligible term a quoted FTS5 phrase, AND-joined
  (`"brut" AND "concrete"`). Unit-testable, parallels `ftsMatchQuery`.
- Hoist `trigramMatch` beside `ftsMatch`: `nil` on trailing whitespace (finished
  word → exact) or when no term is ≥3 chars. Reused by the WHERE arms + ordering.
- `searchAssets` text branch: ADD `source_trigram` / `asset_trigram` OR arms
  (when `trigramMatch != nil`); the collection-name and tag-name arms become
  `*_trigram MATCH` when eligible, else the Phase-1 LIKE fallback. `tagNameContains`
  conjunct gets the same trigram-or-LIKE treatment.
- `ordered(by:match:trigramMatch:)`: add the two direct-field trigram arms scoring
  a flat `substringBase` (between tier-0 `bm25` and `ocrBase`), listed explicitly
  so a name-substring + OCR row still ranks at the substring tier, not OCR.

### 3. UI — none
Substring is a transparent backend recall/ranking improvement; the search field,
tokens, `tag:` parsing, prompt copy, and the closure seam are unchanged.

## Tests

- `trigramMatchQuery` unit table (`FTSQueryBuilderTests`): empty/whitespace → nil;
  single ≥3-char phrase; <3-char term disqualifies the whole query; multi-term
  AND; quote-doubling; operator neutralization; unicode grapheme counting.
- Migration v13 path (`MigrationV13Tests`): the four tables exist; pre-existing
  rows back-fill and substring-match; case/diacritic folding; post-migration
  insert + rename stay indexed via the regenerated triggers.
- e2e (`ServicesSearchPhase2Tests`): substring recall on title / name / tag /
  collection; multi-term AND; <3-char boundary + LIKE fallback (free text and
  `tag:`); trailing-space suppresses substring; relevance word > substring > OCR
  (relative order only, never bm25 floats).

## Verification

1. `cd AtelierCore && swift test` (all suites)
2. `xcodebuild test -project AtelierRefs/AtelierRefs.xcodeproj -scheme AtelierRefs`
3. Manual: type "air" in the gallery → items titled/named "…chair…"; name an item
   "Brutalism", search "utal"; a `tag:` mid-word substring; confirm "typo " (with
   space) stays exact.

## Changelog

`.change-log/217-search-overhaul-phase2.md` — summary, files, migration note
(v13 trigram indexes: additive, automatic, transactional back-fill).

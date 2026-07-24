# 045 — Search Overhaul: Phase 1 Plan (keyword backbone)

Approved implementation plan for Phase 1 of the search overhaul. Background and
option evaluation: `044-search-overhaul-research.md`. Every decision below was
reviewed interactively (17 issues across architecture / code quality / tests /
performance / filtering), all resolved to the recommended option.

## Context

Search is FTS5 whole-word exact match only (`ftsMatchQuery` quotes every term,
neutralizing prefix syntax), recency-ordered with no relevance ranking, and
misses key fields: user-given `asset.name` / `asset.note` are in no index, and
collection names are unsearchable. Scoping is limited to this-collection/all on
a collection screen; tag-only search requires picking a suggestion token.

Out of scope: trigram substring (Phase 2), embeddings (Phase 3), `SearchRules`
v2, field grammar beyond `tag:`, FTS `prefix=` indexes.

## Decided design (issues 1–17)

- **1A** name/note as `asset_fts` columns (migration rebuild; GRDB
  `synchronize(withTable:)` triggers keep `setName`/`setNote` search-visible —
  no derivation duplication).
- **2A** collection-name search = query-time LIKE subquery arm (no new index;
  trivial at collection cardinality).
- **3A** explicit `sort: .newest | .relevance` param on `searchAssets`;
  `.relevance` = best-of-arms BM25 via scored UNION; `.relevance` + keyset
  cursor throws; default `.newest` keeps all existing callers unchanged.
- **4A** no anticipatory Phase-3 seams.
- **5A** prefix-star the trailing term only, and only when the input lacks
  trailing whitespace (trailing space = completed word → exact).
- **6A** shared `containsPattern(_:)` helper (escape + `%…%`) for tag +
  collection arms; FTS arm SQL stays literal (no arm-builder abstraction).
- **7A** `LibrarySearchModel` logs failures (`os.Logger`) + `assertionFailure`
  in debug; no `try?` swallowing in suggestions; generic UI copy unchanged.
- **8A** `sort`, `tagNameContains`, and plural collection scope recorded in
  `SearchRules`' deliberately-not-saved header list AND asserted excluded in the
  codec mapping test (015 drift guard).
- **9A** unit table for `ftsMatchQuery`/`containsPattern` + 2–3 e2e prefix tests.
- **10A** full migration-path test (backfill + trigger proof).
- **11A** relevance tests assert relative order only, never BM25 floats.
- **12A** two-closure seam (`runQuery`/`fetchSuggestions`) on `LibrarySearchModel`.
- **13A** accept the two documented leading-wildcard LIKE scans (Phase 2 trigram
  is the designed replacement).
- **14A** star the trailing term only when ≥2 chars (perf cliff + noise guard).
- **15A** synchronous transactional `asset_fts` rebuild in the migrator
  (one-time, small content — OCR lives in `analysis_fts`, untouched).
- **16A** collection scope TOKENS (folder glyph, suggested beside tags,
  multiple = OR); backend `collectionID: UUID?` → `collectionIDs: [UUID]`
  (empty = unscoped); `SearchRules.collectionID` stays singular.
- **17A** `tag:` narrows suggestions to tags; picking one = a normal token (no
  backend change); unresolved `tag:x` on submit → new explicit
  `tagNameContains: String?` conjunct (ANDs with token `tagIDs`).

## Implementation steps

### 1. Migration — `AtelierCore/.../Persistence/Migrator.swift`
New migration after current head: drop `asset_fts`; recreate with
`t.synchronize(withTable: "asset")` and columns `search_text`, `name`, `note`
(mirror the v6 creation). GRDB backfills + regenerates triggers.

### 2. Query layer — `AtelierCore/.../Services/AppServices.swift`
- `ftsMatchQuery`: star trailing term per 5A/14A (`"wo"*` quoted-prefix syntax;
  quoting/escaping unchanged). Stays `static` for unit tests.
- New `static func containsPattern(_:)`; tag arm adopts it.
- `searchAssets`:
  - `collectionID` → `collectionIDs: [UUID] = []` (IN-list in the membership
    subquery). Update all callers; saved-search evaluation passes `[id]`.
  - New OR arm: collection-name contains (JOIN `collection_item` × `collection`).
  - New conjunct `tagNameContains: String? = nil` (AND, composes with `tagIDs`).
  - New `sort: SearchSort = .newest`; `.relevance` restructures the text branch
    into scored UNION subqueries, best `bm25()` across the three FTS arms (LIKE
    arms score neutral), ordered rank then id; `.relevance` + cursor throws
    (match existing error idiom).
- Extend the LIKE-scan comment to cover both arms (13A).

### 3. Rules contract — `AtelierCore/.../Services/SearchRules.swift`
Header's deliberately-NOT-saved list gains `sort`, `tagNameContains`, plural
scope, with one-line rationales. No shape change; `currentVersion` stays 1.

### 4. UI — `AtelierRefs/AtelierRefs/LibrarySearch.swift`
- `TagToken` → two-case `SearchToken` (`.tag` / `.collection`); folder glyph for
  collections; sparkles/tag glyphs preserved.
- Suggestions: collections beside tags (prefix over collection names); `tag:`
  narrows to tags only; selected-token pruning as today.
- Leftover `tag:x` on submit stripped from FTS text, passed as `tagNameContains`.
- Two-closure seam defaulted to real `AppServices` calls (12A).
- Error logging per 7A. Prompt string updated to teach the new coverage/syntax.

## Tests

- `ftsMatchQuery` unit table: empty, whitespace-only, single/multi term, trailing
  space suppresses star, <2-char not starred, embedded/lone quotes, unicode.
  `containsPattern` escape table (`%`, `_`, `\`).
- e2e prefix: "typo" finds "typography"; trailing space doesn't; 1-char exact-only.
- Migration path: seed previous-version DB → migrate → old `search_text` still
  matches; pre-existing name/note backfilled; post-migration `setName` searchable.
- Relevance: name-match outranks OCR-match; more matched terms outrank fewer;
  deterministic id tiebreak; `.relevance`+cursor throws.
- Filters: collection arm finds members; plural `collectionIDs` = OR;
  `tagNameContains` ANDs with `tagIDs`; empty needle no-ops; codec test asserts
  sort / tagNameContains / plural scope NOT representable in rules.
- `LibrarySearchModel` via seam: failure sets `queryFailed` + clears results;
  success clears flag; rapid retype cancels; suggestion failure → empty without
  flag; `tag:` narrowing; token pruning.

## Verification

1. `cd AtelierCore && swift test`
2. `xcodebuild test -project AtelierRefs/AtelierRefs.xcodeproj -scheme AtelierRefs`
3. Manual: prefix search from gallery; name an item then find it by name; `tag:`
   narrowing; collection token from gallery; collection screen's scope toggle
   still works.

## Changelog

Add `.change-log/` entry (next index): summary, files changed, migration note
(`asset_fts` rebuild — one-time, automatic, transactional). Shipped as `216`.

## As-built notes (refinements found during implementation)

- **Raw text to `ftsMatchQuery`.** The trailing-space → exact rule (5A) needs the
  UNTRIMMED text; `searchAssets` trims for the empty-check and LIKE needles but
  passes the raw text to `ftsMatchQuery` (computed once, reused by the filter arm
  and relevance ordering).
- **Relevance tiers, not raw cross-table bm25.** `bm25()` isn't comparable across
  different FTS tables, so an OCR hit in a long scan could outrank a title hit.
  `ordered(by:match:)` adds explicit additive tier bases: primary fields
  (`source_fts` / `asset_fts` incl. name/note) rank by bm25; a tag-/collection-NAME
  LIKE match sits above them at a neutral base; derived OCR (`analysis_fts`) is
  shifted to always rank last. Verified with `sqlite3` probes before coding.
- **Relevance is correlated ORDER BY, not a CTE.** SQLite accepts FTS5 `MATCH` in a
  correlated subquery, so relevance stays a pure `.order(sql:)` on the existing
  (tested) filter path — `AssetSourceRow` decoding and the newest path are
  untouched.
- **UI wiring.** `LibrarySearchModel` requests `.relevance` whenever there's free
  text to rank, `.newest` for a tokens-only / `tag:`-only query.

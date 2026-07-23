# 216 — Search overhaul, Phase 1 (keyword backbone)

Reworks library search from whole-word exact match into a type-ahead, relevance-
ranked query that covers the fields users actually remember, plus collection
scoping and a `tag:` filter. Phase 1 of a 3-phase roadmap (see
`.docs/044-search-overhaul-research.md` / `045-search-overhaul-plan.md`); trigram
substring (Phase 2) and MobileCLIP/embedding semantic search (Phase 3) are out of
scope here.

## What changed

- **Prefix / type-ahead matching.** `ftsMatchQuery` now emits the trailing term as
  an FTS5 prefix token (`"typo"*` finds "typography") — but only when the input has
  no trailing whitespace (a finished word stays exact) and the term is ≥2 chars.
- **Name / note are searchable.** New migration **v12** rebuilds `asset_fts` with
  `name` + `note` columns; GRDB's sync triggers keep `setName` / `setNote` results
  fresh. A one-time, automatic, transactional rebuild on first launch.
- **Collection names fold into free text**, and a new `tag:` directive filters by
  tag name (`searchAssets(tagNameContains:)`), ANDing with structured tag tokens.
- **Relevance ordering.** `searchAssets(sort:)` adds `.newest` (default) and
  `.relevance` (best-of-arms `bm25()`, with derived OCR explicitly tiered below
  direct fields). The search UI uses `.relevance` whenever there's free text.
  `.relevance` + a keyset cursor throws `AtelierError.relevanceSortUnpageable`.
- **Multi-collection scope.** `searchAssets(collectionID:)` → `collectionIDs: [UUID]`
  (OR across ids; empty = whole library). Collections now appear as suggestable
  scope tokens beside tags in the search field.
- **Error handling.** `LibrarySearchModel` logs query / suggestion failures
  (`os.Logger`) and debug-asserts the relevance/cursor contract, via an injectable
  two-closure seam (`runQuery` / `fetchSuggestions`).

## Files changed

- `AtelierCore/.../Persistence/Migrator.swift` — v12 `asset_fts` rebuild.
- `AtelierCore/.../Services/AppServices.swift` — `searchAssets` (prefix, name/note,
  collection-name + `tag:` arms, plural scope, relevance ordering), `ftsMatchQuery`,
  new `containsPattern`, `ordered` helper.
- `AtelierCore/.../Services/ServiceTypes.swift` — new `SearchSort`.
- `AtelierCore/.../Services/AtelierError.swift` — new `relevanceSortUnpageable`.
- `AtelierCore/.../Services/SearchRules.swift` — documents `sort` / `tagNameContains`
  / plural-scope as deliberately not saved.
- `AtelierRefs/AtelierRefs/LibrarySearch.swift` — `SearchToken` enum, collection
  suggestions, `tag:` parsing, relevance wiring, error logging, closure seam.
- Tests: `FTSQueryBuilderTests`, `ServicesSearchPhase1Tests`, `MigrationV12Tests`,
  `SearchRules` exclusion test, `LibrarySearchModelTests` seam + parse tests;
  `ServicesTagSearchTests` / `MigrationTests` updated for the new API + pin.

## Migration notes

- **v12 is additive and automatic** — it drops and recreates only the derived
  `asset_fts` index (the `asset` table is untouched) and back-fills every existing
  row, so search covers name/note immediately after upgrade. No user action.
- **API break (internal):** `searchAssets(collectionID:)` is now
  `collectionIDs: [UUID]`. Saved searches still carry a single `collectionID`
  (`SearchRules` unchanged); `evaluate` passes it as `[id]`.

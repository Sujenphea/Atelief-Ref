# 167 — Smart collections (saved searches), V1 package core

## Summary

Feature 015 · V1: a **smart collection is a saved search** — a named, rule-based
query ("platform:pinterest AND tag:ui") persisted as its own entity and evaluated
**live** against `searchAssets` every time it opens (never materialized, so never
stale, no membership GC, no writer coupling). This lands the whole package-level
core; the UI (gallery cards, "Save this search", the live grid, ⌘K entries) is V2
and app-side.

The design driver is the **1:1 rule↔query mapping** (015's stated drift risk): a
`SearchRules` value type carries exactly the FILTER arguments of `searchAssets`
(`text`, `platform`, `tagIDs`, `tagMatch`, `collectionID`) — nothing it can express
that isn't a query parameter, nothing a query takes that a rule can't carry. Paging
and sort are deliberately NOT rules (they're evaluation-time / display concerns).

### What's included

- **Schema** — migration **v8** adds one additive `saved_search` table (id, name,
  versioned `rules` JSON, timestamps). Independent of the library schema (like v3's
  ledger / v7's analysis index — no table rebuild). A smart collection is its OWN
  entity, not a `collection` flag (the 005 O3 lesson: don't overload the folder
  table with rows that have no memberships, order, or drop targets).
- **`SearchRules` codec** — a versioned, forward-compatible JSON blob. The embedded
  `version` lets the shape grow (kinds, color, favorite) without a migration. A
  newer blob's unknown fields are ignored, and unknown enum tokens degrade to
  "conjunct dropped" (`platform` → nil, `tag_match` → `.all`) rather than failing
  the whole rule — 015's "evaluate what parses". Normalizes on construction (trims
  text → nil, de-dupes tag ids) so equal-but-differently-written rules share one
  canonical, deterministic (sorted-key) blob.
- **CRUD services** — `createSavedSearch`, `savedSearches` (newest-first),
  `savedSearch(id:)`, `renameSavedSearch`, `updateSavedSearchRules`,
  `deleteSavedSearch`. Deleting a saved search deletes the QUERY only — it has no FK
  to assets or tags (tags are referenced by id inside the rules JSON), so it can
  never cascade an asset away.
- **Live evaluation** — `evaluateSavedSearch(id:)` / `evaluate(rules:)` decode the
  rule and run it through `searchAssets`. The interesting edges are handled
  explicitly:
  - a **deleted-tag conjunct is dropped** (the surviving tags still filter — a
    broadened result, never a silently-empty one), and `savedSearchMissingTags(id:)`
    reports exactly which tags went missing so the card can badge it;
  - a **renamed tag stays matched** (rules store ids, not names);
  - a **corrupt rules blob throws** `.invalidSavedSearchRules` rather than
    evaluating to nothing.

## Files changed

### AtelierCore
- `Persistence/Migrator.swift` — register **v8**; `createV8Schema` (saved_search).
- `Domain/SavedSearch.swift` (new) — the record (opaque versioned `rules` TEXT).
- `Persistence/SavedSearch+GRDB.swift` (new) — `AtelierRecord` conformance.
- `Services/SearchRules.swift` (new) — the rule vocabulary + versioned codec +
  `SavedSearch.decodedRules` / `SearchRules.referencesUnknownVersion` seams.
- `Services/ServiceTypes.swift` — `TagMatch` gains a `String` rawValue + `Codable`
  / `CaseIterable` so it can serialize inside a rule (additive; `searchAssets`
  unaffected).
- `Services/AtelierError.swift` — `.invalidSavedSearchRules(id:)`.
- `Services/Validation.swift` — `savedSearchName`.
- `Services/AppServices.swift` — the CRUD + evaluate surface (015 section).

### AtelierCoreTests
- `SearchRulesTests.swift` (new) — the codec matrix: round-trip per dimension +
  every platform / tag-match; normalization; determinism; version stamping +
  preservation; forward-compat (unknown fields / enum tokens / non-UUID tag ids);
  corrupt-input → nil.
- `ServicesSavedSearchTests.swift` (new) — CRUD (create/read/validate/list/rename/
  update/delete), the 1:1 evaluate proof (text / platform / tag `.all`+`.any` /
  collection / whole-library / limit), and the semantic edges (deleted-tag drop +
  badge, rename-safe, corrupt-throws).
- `MigrationTests.swift` — `committedIdentifiers` + `"v8"`, `expectedTables` +
  `"saved_search"`, v8 schema-shape + record round-trip suites.

## Migration notes

Additive `saved_search` table (v8); no rebuild, no data backfill. Existing
databases gain an empty table on next open. [008] export/import should include
`saved_search` rows in the manifest (portable); a future-version rule blob imports
and "evaluates what parses" (the codec already tolerates it). Full AtelierCore
suite green (**415 tests**, +47).

## Verify

- `swift test --package-path AtelierCore` — 415 tests green.

## Deferred (015 · V2, app-side / needs Xcode)

"Save this search" from the search UI, gallery cards + newer-version/missing-tag
badges, the live grid screen (reusing the collection grid), ⌘K entries, and [009]
move-target / drop exclusion (a smart collection can't be a drop target). The
result-count-per-card `COUNT` query is a V2 display optimization (evaluation
already returns the rows). The seams for all of these exist in this core.

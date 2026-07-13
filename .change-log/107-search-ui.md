# 107 — Search UI: token field, results grid, detail overlay (007 G2)

The app-facing search surface, closing feature 007. A `.searchable` token field
on the Collections gallery (global) and every Collection screen (scoped), with a
results grid that opens the detail page.

## Summary

- **`LibrarySearchModel`** — the search state machine: `text` (FTS), `tokens`
  (tag filters, ANDed), `scope` (This-collection / All), debounced
  `suggestions` and `results`. Queries through `AppServices.searchAssets`
  (G1) — tag tokens resolve to ids, so **tag text never leaks into FTS**.
  Free-text and tag prefix share the field; typed text is FTS, a picked
  suggestion becomes a token.
- **`LibrarySearchable`** — a container that wraps a screen's content, adds the
  token field, and swaps in the results grid while a search is active. Global on
  the gallery (`collectionID: nil`, no scope toggle); collection-scoped on a
  Collection screen (defaults to This-collection, with an All toggle via
  `.searchScopes`).
- **Suggestions** come from `tagVocabulary(prefix:)` and include **agent tags,
  distinguished** by a `sparkles` glyph (user tags get `tag`) — the confirmed
  "include both, distinguished" decision.
- **Results grid** reuses `AsyncThumbnail`; empty / searching states via
  `ContentUnavailableView`. Tapping opens the presentation-only
  `ItemDetailView` in an **asset-scoped overlay** (`SearchDetailOverlay`) — no
  folder membership (so no folder remove/delete), prev/next across the result
  set, tags via `AssetTagsStore`. Opening records a view (G4 coalescer); closing
  flushes.

## Design notes

- Search is **context-scoped**: each screen owns its own `LibrarySearchModel`
  (`@StateObject`), so pushing into a collection gives a fresh, collection-scoped
  field and popping restores the gallery's. Spaces search stays deferred.
- Default **AND** across tags (progressive narrowing — the reference-library
  mental model), matching the G1 default.
- The model exposes a `configure(services:collectionID:)` seam, so its state
  logic is unit-testable; the async query is thin glue over the G1-tested core.

## Files changed

- `LibrarySearch.swift` — new: `TagToken`, `SearchScope`, `LibrarySearchModel`,
  `LibrarySearchable`, results grid, `SearchDetailOverlay`.
- `CollectionsGalleryView.swift`, `CollectionView.swift` — wrap content in
  `LibrarySearchable`.
- `AtelierRefsTests/LibrarySearchModelTests.swift` — 5 tests (isActive, scope
  toggle visibility, default scope per screen, reset).

## Tests

App **64** green (was 59, +5). Build clean.

## Migration notes

None — search is read-only over existing data.

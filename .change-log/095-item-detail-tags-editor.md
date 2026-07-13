# 095 — Item detail: tags editor

The app's **first tags UI**. The tag backend (`applyTag` / `removeTag` /
`tags(for:)`) shipped with the data core but had zero callers in the app; this
wires it into the detail page's sidebar
([023-item-detail-plan](../.docs/023-item-detail-plan.md), F2).

## Summary

- **`IngestionModel` tag surface**:
  - `@Published private(set) var selectedTags: [Tag]` — the selected item's tags,
    reloaded on selection change and after every edit.
  - `select(_:)` now also loads tags (off-main, publishing only if the item is
    still selected — mirrors `loadPreview`).
  - `addTag(_:)` / `removeTag(_:)` route through `AppServices` with
    `source: .user`; empty/whitespace names are rejected inside the funnel
    (`Validation.tagName`) and surface via `lastError`; a `reloadTagsIfCurrent`
    guard drops edits that land after the user has navigated to another item.
- **`TagsSection`** (new sidebar subview, between provenance and actions): the
  tags as removable chips + an "Add tag…" field that commits on Return. User vs
  agent tags are visually distinguished — agent tags carry a `sparkles` glyph and
  a purple tint — so agent-written organization stays reviewable. A small
  `TagFlowLayout` (`Layout`) wraps chips onto new rows within the 300pt column.

## Files changed

- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `selectedTags` + `loadTags` /
  `addTag` / `removeTag` / `reloadTagsIfCurrent`; `select(_:)` loads tags.
- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `TagsSection`, `TagChip`,
  `TagFlowLayout`.

## Migration notes

None — additive. Tags are `TagSource.user` from this UI; agent tags (written
elsewhere) render read-with-badge and are removable like any other.

## Tests

App builds clean; the `AtelierRefsTests` suite stays green. The tag CRUD itself is
covered exhaustively at the core layer by `ServicesTagsTests` (12 cases:
apply/remove/`tags(for:)`, trimming, idempotency, user-vs-agent distinctness,
`notFound`, empty-name rejection, ordering). No app-level model test was added:
`IngestionModel` has only a no-arg `init()` that opens the real Application-Support
library and binds the capture endpoint — it has no injection seam like
`SpaceModel`, so a hermetic test would require a test-only initializer
(disproportionate for a thin async wrapper over already-tested core methods).

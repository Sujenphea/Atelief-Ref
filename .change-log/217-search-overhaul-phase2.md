# 217 — Search overhaul, Phase 2 (trigram substring)

Adds true SUBSTRING matching to library search — "air" now finds "chair" — and
retires the un-indexed leading-wildcard `LIKE` scans Phase 1 left for tag and
collection names. Phase 2 of a 3-phase roadmap (see
`.docs/044-search-overhaul-research.md` / `046-search-trigram-plan.md`); semantic
/ visual embedding search (Phase 3) is out of scope here. Backend-only — no UI or
API-signature change.

## What changed

- **Substring matching on the short fields.** New migration **v13** adds four
  `trigram`-tokenized indexes — `source_trigram` (title / author), `asset_trigram`
  (user name), `tag_trigram`, `collection_trigram` — each `synchronize`d to its
  base table, so a mid-word substring surfaces the item. OCR and the `note` /
  `search_text` blobs stay `unicode61` (trigram over long prose bloats the index).
- **Augments, doesn't replace.** The `unicode61` `source_fts` / `asset_fts` arms
  stay for whole-word + prefix + `bm25` relevance; the trigram arms add substring
  recall on top. The tag- and collection-name arms (and the `tag:` /
  `tagNameContains` conjunct) now `MATCH` their trigram index instead of a
  `LIKE '%…%'` scan.
- **≥3-char eligibility + fallback.** Trigram needs a 3-char window, so it engages
  only when every query term is ≥3 chars; 1–2 char queries keep the Phase-1
  `unicode61` prefix/exact (and a `LIKE` fallback for tag/collection). A trailing
  space still means "finished word → exact", now suppressing the substring arm too
  (`"typo "` won't surface "Typography").
- **Relevance tiering.** A new tier sits between whole-word and OCR: word/prefix
  (`bm25`) > substring-only (trigram, neutral base) > OCR. The direct-field
  trigram arms are scored explicitly so a name-substring + OCR row ranks at the
  substring tier, not last.
- **Folding.** Trigram indexes use `case_sensitive 0 remove_diacritics 1`, so
  "cafe" finds "Café" — matching the `unicode61` indexes.

## Files changed

- `AtelierCore/.../Persistence/Migrator.swift` — v13: four trigram indexes.
- `AtelierCore/.../Services/AppServices.swift` — `trigramMatchQuery`, trigram OR
  arms + trigram-or-LIKE fallback in `searchAssets`, `ordered(trigramMatch:)`
  substring tier, trailing-space suppression, doc-comment refresh.
- Tests: `FTSQueryBuilderTests` (`trigramMatchQuery` table), `MigrationV13Tests`,
  `ServicesSearchPhase2Tests`; `MigrationTests` pin += `"v13"`.

## Migration notes

- **v13 is additive and automatic** — it only CREATEs the four derived trigram
  indexes (no base table is touched) and back-fills every existing row on first
  launch, so substring search works immediately after upgrade. No user action.
- **No API change:** `searchAssets`' signature is unchanged; substring matching is
  transparent to every caller. GRDB 7 has no built-in trigram descriptor — it's
  configured via `FTS5TokenizerDescriptor(components:)`.

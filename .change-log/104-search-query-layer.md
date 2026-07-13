# 104 — Search query layer (007 G1)

The structured tag/collection filter and token vocabulary on the core search
API — the query half of feature 007. Pure `AtelierCore`; no UI, no schema change.

## Summary

- **`TagMatch`** (`ServiceTypes.swift`) — a query-only enum (`.all` / `.any`)
  for how a multi-tag filter combines. Not persisted, so it lives with the query
  inputs rather than the on-disk `Enums`.
- **`searchAssets` extended** with `tagIDs: [UUID] = []`, `tagMatch: TagMatch =
  .all`, `collectionID: UUID? = nil`. The defaults keep every existing caller
  source-compatible. New WHERE conjuncts AND-compose with the existing
  platform / FTS / keyset-seek clauses:
  - collection scope → `asset.id IN (SELECT asset_id FROM collection_item …)`.
  - tags `.any` → single `IN` subquery; `.all` → `GROUP BY asset_id HAVING
    COUNT(DISTINCT tag_id) = N` (exact set semantics, dup-join-safe). Duplicate
    ids in the filter are collapsed to a distinct set so `N` matches.
  - `id` is qualified to `asset.id` — the required `source` join makes a bare
    `id` ambiguous.
- **`tagVocabulary(prefix:limit:)`** — case-insensitive prefix match (LIKE with
  `ESCAPE '\'` so a user's `%`/`_` are literal), ordered `name, source, id`,
  clamped `1...200`. A blank prefix returns the first `limit` tags. Includes
  both `.user` and `.agent` tags (the caller distinguishes by `Tag.source`) —
  the confirmed "include both, distinguished" decision. **`allTags()`**
  convenience for the full inventory.

## Design notes

- Tags stay out of FTS (spec S1, "explicit over clever"): the token UI resolves
  names → ids, so tag text never enters a MATCH query and can't silently miss.
- View counts / sort ordering are **not** here — that's G3. This commit is
  additive and schema-free (no migration).

## Files changed

- `AtelierCore/Sources/AtelierCore/Services/ServiceTypes.swift` — `TagMatch`.
- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` — extended
  `searchAssets`; `allTags`, `tagVocabulary`, `escapeLikePrefix` helper.
- `AtelierCore/Tests/AtelierCoreTests/ServicesTagSearchTests.swift` — 14 tests
  (AND/OR set semantics over 0/1/2/3 tags, dup-join safety, unknown id, user vs
  agent distinctness, combined text+platform+collection, keyset paging with a
  tag filter, vocabulary prefix/limit/wildcard-escape, allTags order).

## Tests

Core **249** green (was 235, +14).

## Migration notes

None — additive API, no schema change. Existing `searchAssets` callers are
unaffected (all new parameters default).

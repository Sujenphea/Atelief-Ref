# 015 — Smart Collections: Saved Searches as Live Collections

> Rule-based live collections ("platform:x AND tag:ui AND favorite") layered on
> [007]'s query engine. Small, high-leverage 007 follow-on.

## Current state

- [007] designs `searchAssets(text:platform:tagIDs:tagMatch:collectionID:…)` —
  every rule a smart collection needs is (or will be) a query parameter there.
  Nothing persists a query; nothing surfaces one as a browsable collection.

## Design

### Storage — a separate table, not a collection flag

```sql
CREATE TABLE saved_search (
  id TEXT PRIMARY KEY, name TEXT NOT NULL,
  rules TEXT NOT NULL,              -- versioned JSON of the query params
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
```

- ✅ Explicit: a smart collection IS a saved query, so it gets its own entity.
  `rules` carries a `version` field (the [081]-manifest discipline) so the shape
  can grow (kinds from [003], color from [012], favorite from [011]).
- Rejected: a `type` flag + rules column on `collection` — overloads the folder
  entity with rows that have no memberships, no manual order, no nesting, can't
  hold drops; every collection consumer would need a discriminator check
  (the [005] O3 lesson).

### Evaluation — live query, no materialization

Opening a smart collection runs `searchAssets` with its rules; results reuse the
collection grid (justified layout, selection, detail — all of [009]/[011] free).

- ✅ Never stale, no membership GC, no writer coupling. Result count on the card
  is one `COUNT` query (cheap; cache per gallery visit).
- Rejected: materialized `collection_item` rows synced on every write — staleness
  windows, GC, and a write-amplification tax on every ingest, for zero user
  benefit at this library scale.

### Semantics (explicit, the interesting edges)

- **No manual order** — sort = [007] modes minus `.manual` (default `.newest`).
  Drag-reorder disabled; **drag-out ([011]) and drag-to-move ([009]) still work**
  (moving changes real memberships; the smart result recomputes on next load —
  an item can legitimately vanish mid-triage if it no longer matches; the grid
  animates removal rather than pretending).
- **Not drop targets** (can't add to a query) — excluded from [009]'s stack row
  and rail, and from Move to ▸ lists.
- Deleting a smart collection deletes the query only — never touches assets.
- Creation UX: "Save this search" from [007]'s search UI (the search field state
  IS the rule editor — no separate rule-builder UI in v1) + rename/edit-by-
  rerunning-and-resaving.
- Gallery placement: cards with a distinct badge/tint after the real collections;
  in ⌘K ([011]) like any collection.

## Schema / migration impact

One additive table (can ride any nearby migration slot — sequencing note in
[003]). [081] export includes `saved_search` rows in the manifest (portable);
import replays them (unknown newer rule versions → import with a warning,
evaluate what parses).

## Phased implementation

1. **V1 (S)** — table + CRUD services + versioned rules codec (round-trip
   tested).
2. **V2 (S–M)** — "Save this search", gallery cards + badge, live grid screen,
   ⌘K entries, [009] target-exclusion.

## Test strategy

- Rules codec: golden-file round-trip, unknown-future-version handling, every
  param combination maps 1:1 onto `searchAssets` arguments (exhaustive matrix —
  the drift risk lives here).
- Semantics: smart collections absent from move-target lists; delete leaves
  assets untouched; count query matches result set under paging.
- Grid reuse: mid-triage vanish (item stops matching) drives one reload, no
  crash, selection pruned ([009]'s stale-selection guard covers it — assert).

## Effort: **S–M** (after 007 G1/G2)

## Risks & edge cases

- Rule drift: every new `searchAssets` capability must decide "exposed in rules
  or not" — the codec's exhaustive mapping test makes forgetting loud.
- A rule referencing a deleted tag: drop the missing conjunct at evaluation,
  badge the card ("references a deleted tag") — explicit over silently-empty.
- Renaming a tag used in rules: rules store tag IDs, so renames are free (assert
  in a test).

## Settled decisions

- Separate `saved_search` entity; live evaluation (no materialization); v1 rule
  editor = the search UI itself.

## Open questions

1. Smart collections in the [009] rail as *navigation* entries (read-only,
   non-drop)? (Recommend yes, visually separated.)
2. Nesting/grouping of saved searches (recommend no — flat list until it hurts).

## Status — V2 shipped in 099 · P4 ([473](../.change-log/473-the-saved-search-becomes-a-place.md))

V1 (the table, the CRUD services, the versioned rules codec) shipped with 015's own
work and has been covered by `ServicesSavedSearchTests` since. **V2 landed in
099 · P4** and the app can now reach every one of those services:

- A flat "Smart" section in the sidebar below Spaces (SwiftUI — 099 · decision 7A: no
  reorder, so no `NSOutlineView`), inline rename, delete behind the shared
  confirmation; Home cards **after** the real collections with their own `CardTint`.
- The grid is a per-window `CollectionReadModel` on the saved-search feed. Sort is
  007's modes minus `.manual`, DERIVED from `SortMode.allCases` rather than typed out.
  Drag-reorder is off; drag-out and drag-to-a-collection work and resolve as a COPY,
  because a query has no collection to move OUT of.
- "Save this search…" is in the search field's toolbar (⌘S), enabled only on a
  non-empty query. **Re-saving while a smart collection is open replaces THAT
  search's rules** — this doc's "edit-by-rerunning-and-resaving", made concrete.
- Both badges — *references a deleted tag*, *can't read this search* — are one value
  drawn by one view on the sidebar row and the grid header alike.
- The exclusions ("not drop targets", "excluded from Move to ▸ lists", "no manual
  order") are asserted rather than left implicit, in `SmartCollectionExclusionTests`.

### One claim in this doc is NOT true, and was not made true

> [081] export includes `saved_search` rows in the manifest (portable); import
> replays them.

**`ArchiveManifest` carries no such rows**, and [081](081-backup-plan.md) never said it
did — the claim is this doc's alone, written before the manifest was. It was not added
in P4 because the shapes do not meet: the manifest deliberately carries **no tag id**
(`TagEntry` is `(name, source)` — "an importer mints its own"), while `SearchRules`
references tag ids, and the importer mints new collection ids too. A blob copied
verbatim would point at ids present in neither table in the destination library, import
as a smart collection matching the wrong things, and badge itself as referencing deleted
tags. Making saved searches portable needs a rule-remapping design — tag ids in the
manifest, or a name-keyed rule translation — that no doc specifies. The gap is asserted
in `LibraryArchiveRoundTripTests.savedSearchesDoNotYetCrossTheArchive`, which fails the
day someone adds the rows without deciding about the ids.

### Open question 1, answered

*Smart collections in the [009] rail as navigation entries (read-only, non-drop)?* —
**yes**, and that is what the Smart section is: `SidebarItem.acceptsAssetDrops` returns
`false` for `.savedSearch`, exhaustively and under test. Open question 2 (nesting)
stays **no**; the list is flat.

# 043 · Nested Collections UI — Plan

> **Status:** revised after a structured design review (2026-07). Supersedes the
> initial SwiftUI-only approach (changelog 203). The drag layer is being rebuilt
> on AppKit `NSOutlineView` with a persisted manual order.

## Background

Nested collections were already supported end-to-end in the domain/persistence/
service layers. Changelog 203 surfaced them in the UI, including a first drag pass
using SwiftUI `.draggable`/`.dropDestination`. That pass did not feel right:
per-row `.dropDestination` on plain `VStack` rows is unreliable to hit-test and
gives no live feedback. The request ("dragging doesn't work as expected, can it
be live reorder") triggered this review.

## Decisions

| # | Area | Decision |
|---|------|----------|
| 1 | Drag container | NSOutlineView tree (retire the SwiftUI VStack tree) |
| 2 | Order semantics | Persisted Collection.sortIndex + migration + reorderCollections |
| 3 | Nav | Reconcile NavModel after delete/reparent (scoped) |
| 4 | Expansion state | Stays view-layer (outline-view owned, not persisted) |
| 5 | Reparent validity | One pure CollectionTargets.canReparent(...) predicate |
| 6 | Name alerts | Shared NameEntryAlert component (dedupe 3 blocks) |
| 7 | Names | Trim at model boundary; document duplicate-name policy |
| 8 | Menus | Unify the two SwiftUI move-target menu builders |
| 9 | Tests: order | Full gapless-invariant suite |
| 10 | Tests: validity | Exhaustive canReparent table tests |
| 11 | Tests: nav | Full reconcile-after-delete suite |
| 12 | Tests: drag | CollectionDragPayload round-trip + extracted pure drop-routing funcs |
| 13 | Perf: tree | Memoize derived tree (folders-identity keyed) |
| 14 | Perf: drag | Drag-session descendant-set cache |
| 15 | Perf: refresh | Confirm covers/previews path; fix only if N+1 |
| 16 | Perf: reindex | Dense 0..<n reindex per move |

### Rationale highlights

- 1C (NSOutlineView) over improving the SwiftUI VStack (fragile) or a List/
  OutlineGroup restyle (risky against the hand-tuned sidebar). Matches the
  codebase precedent of AppKit for heavy interaction (grid = NSCollectionView via
  MasonryGridHost).
- 2B (persisted order): "reorder" is meaningless without a manual position —
  collections are (name,id)-sorted today, so drag could only reparent. sortIndex
  enables true drag-to-position AND reparent.
- 16A dense reindex over fractional/gap indexing: sibling counts are small, so
  O(n) writes are negligible and the gapless invariant is obvious + testable.
- 5A single predicate removes a 4-way duplication of the cycle/self check that
  would become 5-way with the outline coordinator.

## Survives vs. retired (from changelog 203)

Kept/extended: CollectionDragPayload + Info.plist type; CollectionMoveToMenu;
CollectionTargets.folderMoveTargets/descendantIDs + tests; Home card menus;
in-place subfolder create/rename (moved behind NameEntryAlert).

Retired: the SwiftUI SidebarView VStack tree (flattenedRows, collectionTreeRow,
overlay chevron, acceptReparent) -> NSOutlineView bridge. Breadcrumb +
collectionBreadcrumb helper (already removed).

## Build sequence (each phase shippable + tested)

> **All phases A–F landed** on `feat/collection-manual-order` (commits
> `83cfdc7` → `7418efb`). Changelogs 203–212. Full suite green: 559 app +
> 440 AtelierCore tests. Remaining work is the two product decisions in
> *Open items* below, not build tasks.

- Phase A ✅ — Data foundation (2B/9A/16A): Collection.sortIndex; migration +
  deterministic seed; service create(append)/delete(close gap)/move(append)/
  reorderCollections maintaining dense gapless order; tree/gallery sort by
  (parent, sortIndex). -> 9A invariant suite.
- Phase B ✅ — Pure helpers (5A/7A/10A): canReparent(...); trim in createFolder/
  renameFolder (7A was moot — `Validation.collectionName` already trims). -> 10A
  table tests.
- Phase C ✅ — NSOutlineView sidebar (1C/13A/14A/12A): NSViewRepresentable +
  coordinator mirroring MasonryGridHost; live reparent + reorder; extracted pure
  drop-routing funcs; memoized tree; drag-session cache. -> 12A tests. SwiftUI
  tree retired.
- Phase D ✅ — Nav reconcile (3A/11A): `NavModel.reconcile(using:)` on every
  folder refresh drops routes to a deleted collection back to Home / a valid path
  prefix; subsumed the one-shot restore validator. -> 11A tests (changelog 210).
- Phase E ✅ — Dedupe (6A/8A): shared `nameEntryAlert` modifier (8 prompts → 1);
  8A already satisfied (both SwiftUI move-to sites use `CollectionMoveToMenu`; the
  AppKit NSMenu builder stays separate). Changelog 211.
- Phase F ✅ — Perf confirm (15B): covers/previews are all single set-based
  queries, no per-collection N+1. Audit-only, no code change. Changelog 212.

## Open items — RESOLVED

1. Gallery reorder scope → **(b) keep Home reparent-drop-only.** The sidebar tree
   is the reorder surface; a sidebar reorder reflects on Home via shared
   `sortIndex`. No code change.
2. Duplicate-name policy → **(2c) Finder-style auto-disambiguate** ("Refs" →
   "Refs 2"), applied on create + rename (not move — see changelog 213 for the
   scope note). Changelog 213.

## Testing plan (consolidated)

- 9A — after any create/delete/reparent/reorder/undo sequence, each parent's
  children are 0..<n, no gaps/dupes; migration seeds a deterministic order.
- 10A — canReparent: self, direct child, deep descendant, corrupt 2-cycle,
  Unsorted target, nil/top-level, unrelated, unknown ids.
- 11A — nav reconcile: delete open -> fallback; delete in drill path -> prune;
  delete unrelated -> no-op; reparent open -> stays valid.
- 12A — CollectionDragPayload round-trip (mirror AssetDragPayloadTests); pure
  drop-routing funcs (source + target row + drop position -> reparent /
  reorder-to-index / reject).

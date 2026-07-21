# 188 — Detail: non-disruptive Most-Viewed reorder (036 §3 B4)

## Summary

Closing the item-detail overlay used to call `IngestionModel.flushViewBumps`,
which — when the folder ranks by views — fired a **full `loadContents` reload**
to re-apply the Most-Viewed sort. That reload republishes `items` from the
database and re-materializes the entire grid: the last detail-churn source root
cause 3 named. B4 replaces it with a **local, pure reorder** that reproduces
core's order exactly and lands **after** the close fade, so the just-viewed item
rises in place with no grid churn.

This is the final step of Workstream B — the detail path (open, step, close) is
now smooth end to end.

### What changed

- **New `MostViewedReorder.swift`** — pure `mostViewedReorder(items:bumps:)`:
  bakes per-asset view-count deltas into a copy, **stable-sorts** by core's exact
  tiebreak `view_count DESC, created_at DESC, id DESC`, and returns `.unchanged`
  when the membership order didn't move (so the caller skips the publish — the
  common case of viewing an already-top item). The comparator `mostViewedPrecedes`
  is exposed for tier-by-tier tests. Stability comes from a final original-index
  ascending key (Swift's `sorted(by:)` isn't stable).
- **`ViewBumpCoalescer.drain()` now returns per-id counts** (`[UUID: Int]`, was
  `Set<UUID>` → `[UUID]`). Tests updated to the count contract.
- **`IngestionModel`**
  - `flushViewBumps` no longer reloads on success. It folds each distinct drained
    id into a new **non-published accumulator** `pendingReorderBumps` (+1 per id —
    matching core's one-`view_count`-bump-per-batch, NOT the raw open count),
    persists via `recordViews`, and reorders **in place** only when the folder is
    Most-Viewed AND the detail overlay is **not** up. While the overlay is up
    (`isDetailPresented`) the reorder is **deferred**.
  - New `applyDeferredMostViewedReorder()` — the deferred reorder, called by the
    host in the close animation's completion. Publishes `items` once (deltas baked
    in, so `items` again equals DB truth) only when the order changed; otherwise
    keeps the accumulator and publishes nothing.
  - `loadContents` clears `pendingReorderBumps` (a genuine reload IS DB truth).
  - New plain (non-`@Published`) `isDetailPresented` flag.
- **`CollectionView` / `CollectionDetailHost`**
  - `onChange(of: presentedItemID)` toggles `model.isDetailPresented` on the
    overlay lifecycle (covers every open source, plus close and auto-dismiss).
  - `close()` flushes while the overlay is still up (so the reorder defers), then
    `withAnimation { presentedItemID = nil } completion:` applies the deferred
    reorder after the fade. Lead-on-open unchanged; step still never sets the lead.

### Why an accumulator (order-divergence guard)

The reorder must produce **byte-identical** order to `loadContents`, or the next
genuine reload snaps items into different places. Skipping the publish when order
is unchanged would, on its own, *lose* the bump locally — so a later flush would
recompute order from stale counts and could diverge from the database (e.g. a
second-place item that quietly reaches a tie with the top item). `pendingReorderBumps`
holds the persisted-but-not-yet-baked deltas across skips, preserving the invariant
`items.viewCount + pendingReorderBumps == DB.view_count` at all times, so every
reorder sorts on the same effective counts core would.

### Comparator proven against core

`MostViewedReorderTests` includes a **gold-standard** test that seeds a real temp
`AppServices`, records an uneven view spread, and asserts the local reorder equals
core's actual `collectionItems(sort: .mostViewed)` SQL order — not a hand-copied
comparator. Colors seeded in a tight loop share `created_at`, so the untouched
majority ties on `view_count` and `created_at`, exercising the `id DESC` tiebreak
against the database itself. Field-tier, stability, skip-when-unchanged, per-id
bump, and tie-resolution cases are covered separately.

## Files changed

- `AtelierRefs/AtelierRefs/MostViewedReorder.swift` (new)
- `AtelierRefs/AtelierRefs/ViewBumpCoalescer.swift`
- `AtelierRefs/AtelierRefs/IngestionModel.swift`
- `AtelierRefs/AtelierRefs/CollectionView.swift`
- `AtelierRefs/AtelierRefsTests/MostViewedReorderTests.swift` (new)
- `AtelierRefs/AtelierRefsTests/ViewBumpCoalescerTests.swift`

## Migration notes

- `ViewBumpCoalescer.drain()` return type changed (`[UUID]` → `[UUID: Int]`). The
  only caller is `IngestionModel.flushViewBumps`; it uses `Array(counts.keys)` for
  the (dedup-coalescing) `recordViews` write.
- **Error fallback preserved:** a `recordViews` failure now falls back to the full
  `loadContents` reload (for a Most-Viewed folder), so local order can never drift
  from the persisted truth; a non-reordering folder rolls the optimistic deltas
  back out of the accumulator instead.
- No schema, no persisted-format, and no core changes.

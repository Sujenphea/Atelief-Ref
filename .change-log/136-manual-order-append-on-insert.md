# 136 — Manual grid: new items append to the end (not a random slot)

## Summary

A new item added to a collection now lands at the **end** of the Manual grid, in
insertion order — instead of appearing at a random position.

Previously every new membership was inserted with `manual_order = NULL`. The Manual
sort is `ORDER BY manual_order, id`, and SQLite sorts NULLs first, so new items
jumped to the **front**; when several were added at once they tied on
`collection_item.id` — a random UUID — so their order looked random. `addedAt` (a
perfectly good chronological key) was never used for ordering.

## Changes

- **`AppServices.nextManualOrder(_:collectionID:)`** (new, `AtelierCore`): returns
  `COALESCE(MAX(manual_order), -1) + 1` for a collection — the next append slot, or
  0 when it has no ordered items. SQLite makes uncommitted inserts visible within
  the same transaction, so a batch calling it per item still increments correctly.
- **All three membership-insert sites** now assign that slot instead of `nil`:
  - `ingest(...)` (blob path) and `ingestContent(...)` (media-less path) — one
    membership per (serialized) `write`, so each new item gets the next slot.
  - `addAssets(_:to:)` — computes the base slot once and increments locally per
    newly-inserted membership (already-member assets are skipped and don't consume
    a slot).

`setGridOrder` (drag reorder) is unchanged: it still rewrites `0…n` over the whole
loaded list, so dragging continues to work exactly as before.

## Tests

- New `ServicesSortTests` cases: ingest appends in insertion order; a fresh ingest
  lands **after** an existing `setGridOrder` arrangement; `addAssets` appends the
  batch in order and doesn't re-slot an already-member asset.
- Updated `ServicesInvariantTests/gridOrderRollback`: it asserted a rolled-back
  `setGridOrder` left the member's order at `nil`; the append-on-insert baseline is
  now `0`, so the test captures the pre-call order and asserts it is **unchanged**
  by the rollback (tracks the atomicity invariant, not a hardcoded value).
- Full `AtelierCore` suite (311) passes; app target builds.

## Notes / not included

- **Legacy NULL rows are not backfilled.** Collections whose items predate this
  change still carry `manual_order = NULL` and will show those items first (in the
  old id-random order) until a drag reorder flushes them via `setGridOrder`. A
  one-time migration assigning `addedAt`-ordered indices to existing NULLs would
  fully normalize this if desired — deferred for now.

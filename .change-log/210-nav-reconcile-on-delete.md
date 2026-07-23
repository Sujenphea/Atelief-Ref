# 210 · Route reconcile after collection delete (043 Phase D · 3A/11A)

## Summary

Nav route state now self-heals when a collection disappears. Deleting a folder
removes its whole subtree; previously a sidebar selection or drill-down `path`
still pointing INTO that subtree became a dangling route (blank panel / stuck
drill-down). `NavModel.reconcile(using:)` runs on every folder refresh and drops
the invalid routes back to a valid target.

## What changed

- **`NavModel.reconcile(using:)`** (043 · 3A) — run from `ContentView`'s
  `onReceive(model.$folders)`:
  - a drill-down `path` truncates at the FIRST entry whose collection is gone
    (everything deeper was reached through it, so it is invalid too);
  - a deleted sidebar `.collection` selection falls back to **Home**.
  - No-op until folders load (empty list = "not yet loaded"; the DB always has
    Unsorted) and no-op when nothing is missing — so launch with the restored
    collection present mutates nothing and the `NavigationStack` observer stays
    quiet (004 launch semantics preserved).
  - Falls back to Home rather than the deleted collection's PARENT: a subtree
    delete can take the parent too, and it is no longer in `collections` to
    consult. Home is the one always-valid target.
- **`NavModel.reconciled(selection:path:existing:)`** — the pure, `nonisolated`
  truncate/fallback core, kept SwiftUI-free so it is unit-tested directly.
- **Removed `pruneRestoredPathIfMissing` + `didValidateRestore`** — the one-shot
  launch validator was a strict subset of `reconcile` (selection-only, no path
  truncation). `reconcile` subsumes it: its no-op-when-present behavior gives the
  same "no launch-time mutation" guarantee, so the one-shot guard is unneeded
  (DRY — one reconcile path, not two overlapping ones).

## Files

- `AtelierRefs/AtelierRefs/NavModel.swift` — add `reconcile`/`reconciled`; drop
  `pruneRestoredPathIfMissing`/`didValidateRestore`.
- `AtelierRefs/AtelierRefs/ContentView.swift` — call `nav.reconcile(using:)`.
- `AtelierRefs/AtelierRefsTests/NavModelTests.swift` — `NavReconcileTests`
  (10 · 11A): identity when present, selection→Home, surviving selection kept,
  truncate-at-gap, keep-valid-prefix, non-collection routes untouched, space
  route survives a collection gap, empty-list skipped, applies-to-model.

## Notes

Reparent is a no-op here (no collection is deleted → the id set is unchanged),
which is correct: a reparented collection still exists, so its routes stay valid.

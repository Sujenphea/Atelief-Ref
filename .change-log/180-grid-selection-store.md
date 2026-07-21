# 180 — Grid selection extracted onto `GridSelectionStore` (036 §2 A0)

## Summary

Moved the Library grid's multi-selection off the `IngestionModel` god-object into
its own `@MainActor ObservableObject`, `GridSelectionStore`. The selection logic
is unchanged — the pure `GridSelection` reducer stays the only truth; the store is
a thin owner that holds the value + the feed `order` the reducer needs and
forwards mutations through the same seams `IngestionModel` used before.

### Honest scope of the win

This does **not** on its own stop the whole `CollectionView` from re-rendering on
a selection change. That view reads `selection` at ~nine sites in its own body, so
it still re-runs on every click / ⇧-click / arrow / marquee tick until those reads
move down into per-cell views — that is the later A1–A2 work, deliberately not part
of A0. What A0 removes is the **cross-view fan-out**: a selection publish used to
fire `IngestionModel.objectWillChange`, invalidating *every* view observing the
model (toasts, gallery, spaces list, inspector, etc.). Now only subscribers of
`GridSelectionStore` repaint on a selection change — today that is just
`CollectionView`, which observes the store explicitly to keep exact parity.

Behavior is otherwise identical: selection semantics, lead item, `selectedAssetIDs`
contents and ordering, drag payload, action targets, marquee-driven selection, and
keyboard nav all go through the unchanged reducer.

## Files changed

- **New** `AtelierRefs/GridSelectionStore.swift` — `@Published private(set) var
  selection`, a settable `order`, and the mutation seams: `apply(_:columns:) ->
  GridSelectionEffect` (guards real changes, like the old `applySelection`),
  `setLead`, `replace` (the Jump path), `prune(to:)` (contents-reload pruning),
  `setOrder`.
- `AtelierRefs/IngestionModel.swift`
  - Deleted `@Published var selection`; added `let selectionStore` + a computed
    `var selection { selectionStore.selection }` so every internal reader
    (`leadItem`, `selectedAssetIDs`, `dragPayload`, `actionTargets`, keyboard
    targets) is untouched.
  - Removed the hoisted `itemOrder`; `rebuildItemDerivations()` now pushes order
    via `selectionStore.setOrder(...)`.
  - Replaced the old `selection.didSet { rebuildSelectedAssetIDs() }` with a
    Combine sink on `selectionStore.$selection`. `rebuildSelectedAssetIDs(for:)`
    now takes the selection **explicitly**: `@Published` fires on `willSet`, so the
    store's stored `selection` still holds the OLD value inside the sink — the sink
    passes the emitted NEW value, avoiding the stale-read bug the prior session hit.
  - `applySelection` forwards to `selectionStore.apply` (single seam); `loadContents`
    prunes/replaces via the store; `openItem` sets the lead via `setLead`.
- **New** `AtelierRefsTests/GridSelectionStoreTests.swift` — builds a real
  `IngestionModel` over temp `AppServices` (the `AppUndoTests` pattern) and proves
  the willSet/sink timing: a selection through the store lands in
  `selectedAssetIDs` and reads back through the computed `model.selection`; plus
  `applySelection` feed-order parity and `setLead`→`leadItem`.
- `AtelierRefs/CollectionView.swift` — added `@ObservedObject private var
  selectionStore` (wired from `model.selectionStore`) with an explicit init so the
  screen still repaints on selection now that `model.selection` is no longer
  `@Published`. The nine body-level `selection` reads are unchanged (not moved —
  A1–A2 work).

## Migration notes

- `IngestionModel.selection` is now a read-only computed forward; there is no more
  `@Published selection`. Any NEW view that must repaint on a selection change must
  observe `model.selectionStore`, not `model` — reading `model.selection` in a body
  no longer subscribes to it. (Only `CollectionView` needs this today.)
- The selection mutation API is unchanged for callers: `model.applySelection(...)`,
  `model.requestJumpSelection(...)`, `model.openItem(...)` behave exactly as before.
- The store is the seam the AppKit grid coordinator subscribes to in later A-work.

## Verification

- Release build: green (xcodebuild exit 0). No new warnings from the changed files.
- `AtelierRefsTests` (serial, `-parallel-testing-enabled NO`): 373 tests, 0 failures.
- New `GridSelectionStoreTests`: 3/3 passed.

# 106 — Sort UI + view coalescer (007 G4)

The app half of sorting: a per-collection sort menu, drag-reorder gated to
manual mode, and a coalesced view-tracking write wired to the detail-open seam.

## Summary

- **Sort menu** on the Collection screen toolbar — a menu-styled `Picker` bound
  to the stored per-collection `SortMode` (Manual / Newest / Most Viewed).
  Picking one persists via `setCollectionSortMode` (optimistic cache update →
  the toolbar reflects it immediately) and reloads the grid in the new order.
- **Drag-reorder gated to `.manual`** — both at the model (`reorderItem` guards
  on the folder's mode) and the view (`reorder(dropped:)` rejects the drop
  outside manual). Switching to Newest / Most Viewed never rewrites
  `manual_order`, so returning to Manual restores the drag arrangement.
- **`ViewBumpCoalescer`** — a pure value type: a `Set<UUID>` where a burst of
  opens of one asset collapses to a single bump and distinct assets each get
  one. The model owns a short (3s) debounce timer; `flushViewBumps()` drains it
  through `recordViews`.
- **Wired at the detail-open seam only** (the deliberate "I looked at this"
  signal): `recordView` fires on grid open, on a detail-page prev/next step, and
  on a Space asset-detail open; `flushViewBumps` fires on every detail close.
  Grid selection / arrow-key browsing and canvas realization are **not** counted.

## Files changed

- `IngestionModel.swift` — `sortMode(for:)`, `setSortMode(_:for:)`,
  `loadContents` passes the mode; `recordView`/`flushViewBumps` + coalescer
  state; `reorderItem` manual-mode guard.
- `ViewBumpCoalescer.swift` — new pure helper.
- `CollectionView.swift` — sort menu; `recordView` on open + navigator step;
  `flushViewBumps` on close; drop rejected outside manual.
- `SpaceView.swift` — `recordView` on asset-detail open; `flushViewBumps` on
  close.
- `AtelierRefsTests/ViewBumpCoalescerTests.swift` — 4 tests (collapse repeats,
  distinct assets, drain empties, empty-by-default).

## Design notes

- No IngestionModel injection seam exists (it opens the real library), so the
  sort-wiring itself isn't unit-tested at the app layer; the *behaviour* it
  drives — per-mode ordering, non-destructive switching, `recordViews`
  batching — is covered by Core's `ServicesSortTests` (G3). The coalescer, the
  one piece of app-side logic worth isolating, is pure and directly tested.

## Tests

App **59** green (was 55, +4). Core + Ingestion + Server unchanged.

## Migration notes

None (the schema landed in 105 / migration v5). Existing collections default to
`.manual`, so the grid looks and behaves exactly as before until a user changes
the sort.

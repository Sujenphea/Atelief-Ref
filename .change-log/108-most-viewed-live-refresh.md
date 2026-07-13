# 108 — Most-Viewed live refresh + clearer sort menu (007 fix)

Fixes the "most viewed doesn't seem to work" report. The sort backend was
correct end-to-end (verified against the live library: views recorded, mode
persisted, and `collectionItems(in:sort:.mostViewed)` returns the right order —
`[2,1,1,1,1,0]` vs manual `[0,0,0,0,2,0]`). The gap was UI feedback, not data.

## What was wrong

- **The grid never re-sorted after viewing.** The most-viewed ranking only
  reloaded when you *changed the mode* — not after you opened items. So in Most
  Viewed mode you'd view an image (its count rose in the DB), return to the grid,
  and nothing moved: the ranking looked frozen.
- The picker-in-menu also gave weak feedback about which mode was active.

## Fix

- **Live re-rank** — `flushViewBumps` now reloads the current folder after
  writing view bumps *when it ranks by views* (`.mostViewed`), so the
  just-viewed item visibly rises. Manual / newest orders are view-independent and
  are left untouched (no surprise reordering).
- **Clearer sort menu** — replaced the picker-in-menu with explicit checkmarked
  buttons: each persists the mode and reloads the grid, the active mode shows a
  checkmark, and the toolbar label names it ("Sort: Most Viewed").

## Files changed

- `IngestionModel.swift` — `flushViewBumps` reloads on `.mostViewed`.
- `CollectionView.swift` — checkmarked sort buttons.

## Tests

App **64** green; build clean. (Core sort semantics unchanged — already covered
by `ServicesSortTests` and confirmed against the live DB during diagnosis.)

## Migration notes

None.

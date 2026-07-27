# 257 — Spaces import: SP5 undo (placement-only, decision revised)

Phase SP5 of the [059 import-into-spaces plan](../.docs/059-spaces-import-plan.md).
No new machinery — a design revision plus test hardening.

## Decision revised: 7A/16A → placement-only

The original plan (7A/16A) had an external-drop undo also DELETE the newly-ingested
asset via the recoverable `deleteAssets`/`MediaReaper` path. Implementation surfaced
two facts that overturn it:

1. **The imported asset lives in Unsorted.** An external drop ingests into Unsorted
   (a real collection membership) *plus* the board placement — so the asset is never
   "referenced nowhere else", and 7A's own guard would never fire.
2. **Collection imports aren't undoable at all.** The grid's `run()` registers no
   undo; ⌘Z reverses delete / remove / move / reorder / rename, never an *import*.
   Deleting the asset on a *board* import undo would make the board the one
   inconsistent import surface in the app.

So BOTH surfaces now undo the **placement only**; the ingested asset stays in
Unsorted (removable via the normal ⌫ delete if unwanted). This is exactly what the
shared `insertPlaced` pipeline already registered in SP2/SP3 — the S1 inverse needed
no extra code. Consequences:

- **16A is void** — `MediaReaper`/`deleteAssets` stay out of the import path (they
  still power the separate ⌫ delete verb).
- **9A simplifies** — no asset-delete branch, so no shared-reference guard and no
  data-loss case to defend.

## Files changed

- `.docs/058-spaces-import-overview.md`, `.docs/059-spaces-import-plan.md` — 7A/16A/9A
  and the SP5 phase revised to placement-only, with the rationale.
- `AtelierRefs/AtelierRefsTests/SpaceImportPlaceTests.swift` — the S1 undo test now
  asserts the full matrix: after undo the tile is gone but the asset AND its Unsorted
  membership survive; redo restores the tile with a stable id.

## Migration notes

None — behavioural no-op vs SP3 (SP3 already did placement-only undo). Docs +
tests only. No schema change.

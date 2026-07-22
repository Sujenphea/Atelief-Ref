# 200 — Home marquee select + batch delete

## Summary

Home (`CollectionsGalleryView`) gains drag-to-select: a marquee rectangle over the
grid selects collection and space cards across both sections, and the selection is
deletable via ⌫ / a floating action bar, behind ONE confirmation dialog. Unsorted is
never selectable (it can't be deleted).

Decisions (confirmed with the user): both Collections + Spaces in scope; Delete key
+ a contextual action bar; a single batch confirmation dialog.

## How it works

- Reuses the pure geometry `marqueeRect(from:to:)` + `marqueeIndices(in:frames:)`
  (`MarqueeMath.swift`) — the same core the AppKit grid uses; no new math.
- Card frames are captured with `onGeometryChange` (via a small `CardFrameReporter`
  modifier) in a shared named coordinate space `"galleryContent"`, so hit-testing
  works without a per-cell `GeometryReader`.
- A transparent `marqueeCatcher` layer sits BEHIND the cards: a drag on empty grid
  area starts the marquee (a tap on a card still navigates); an empty-area click
  (or Esc) clears the selection.
- Selection lives in a gallery-local `Set<UUID>` (not the Library grid's
  `GridSelectionStore`, which is asset/membership specific).

## Files changed

- `CollectionsGalleryView.swift` — marquee state + gesture + overlay, per-card
  selection ring, the floating "N selected · Clear · Delete N" bar, `onDeleteCommand`
  / `onExitCommand` (focusable, focus-ring suppressed), and the batch confirmation
  dialog with a "N collections, M spaces" breakdown. Added the `CardFrameReporter`
  modifier.
- `IngestionModel.swift` — new `deleteCards(collectionIDs:spaceIDs:)`; extracted
  `deleteSpaceRecoverableWithUndo(id:name:)` from `confirmSpaceDeletion` so the
  single-space delete and the batch delete share one recoverable+undo path.
  Collections delete fire-and-forget (Unsorted guarded); each space is recoverable
  with its own ⌘Z undo.

## Notes / follow-ups

- Deleting collections is not undoable today (matches the existing single-card
  behavior); spaces are. The confirmation dialog is the safety gate.
- Keyboard delete rides `onDeleteCommand` on the focusable gallery; the action-bar
  button is the always-available path.

## Verification

- `xcodebuild -scheme AtelierRefs build` → **BUILD SUCCEEDED**.
- `HomeCardDeleteTests` (new, `AtelierRefsTests`) → 4 pass:
  - `deleteCards` removes selected spaces; each undo restores its board.
  - `deleteCards` deletes a real collection but never Unsorted (guard).
  - mixed batch deletes a collection + a space in one call.
  - `confirmSpaceDeletion` still deletes + undoes after being refactored onto the
    shared `deleteSpaceRecoverableWithUndo` helper (regression guard).
- The marquee gesture / action bar / selection-ring UI wiring is build-verified;
  the pure `MarqueeMath` + `GridSelection` reducer it drives are covered by their
  own existing suites.

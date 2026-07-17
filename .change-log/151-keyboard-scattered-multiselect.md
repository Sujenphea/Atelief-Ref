# 151 — Grid: keyboard scattered multi-select (034 P1)

## Summary

Closes the last P1 keyboard/mouse-parity hole (theme 3): building a **discontiguous
(scattered)** selection from the keyboard. Arrow keys already move the grid cursor
(`lead`) without disturbing the selection set, and ⇧-arrows extend a contiguous
range — but there was no keyboard peer of the ⌘-click / hover-circle toggle.

**X** now toggles the cursor cell in/out of the selection in place. So: arrow to a
cell → **X** to pick it → arrow elsewhere (the set is untouched) → **X** again →
a scattered multi-selection, no mouse needed. `Space` is Quick Look, so **X**
(mnemonic: ✕-a-box) is the free toggle; it's ignored under any modifier so it never
eats `⌘X`.

## Files changed

### AtelierRefs
- `GridSelection.swift` — new `GridSelectionAction.toggleLead`: toggles the current
  `lead` in place (re-pins anchor/lead to it, so the cursor doesn't jump); a no-op
  with no cursor.
- `CollectionView.swift` — `.onKeyPress(keys: ["x"])` on the focused grid routes an
  unmodified X to `.toggleLead`.

### AtelierRefsTests
- `GridSelectionTests.swift` — `toggleLeadSelects`, `toggleLeadDeselects`,
  `arrowsThenToggleScatter` (the end-to-end keyboard-scatter flow), `toggleLeadNoCursor`.

## Migration notes

None. Purely additive; no existing key binding changes.

## Verify

- Grid focused → press → (cursor ring appears on the first cell) → **X** → it
  selects (checkmark, selection mode) → arrow to another cell → **X** → both are
  selected though they're not adjacent → **X** again on one → it deselects.

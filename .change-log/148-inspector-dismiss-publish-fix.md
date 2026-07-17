# 148 — Element inspector: publish-during-update fix

## Summary

Fixes a runtime warning — **"Publishing changes from within view updates is not
allowed, this will cause undefined behavior"** — introduced by the commit-on-dismiss
added in batch 1 (changelog 146).

The element inspector committed pending edits from `.onDisappear`, which fires
*inside* the view-removal update. The commit runs `onCommit` →
`SpaceModel.updateStyle`, which publishes synchronously (`undoToken` bump + a
reload), so every outside-click dismiss published mid-update. Colour round-tripping
(`Color → hex → Color`) left `oldStyle != newStyle` true even when nothing was
edited, so it fired on essentially every dismiss — hence the repeated warnings while
editing frames/text on a Space board.

Fix: split the pure style-building (`builtStyle()`, reads local `@State` only, safe
in `onDisappear`) from the publishing commit, and hop the fallback commit onto the
next main-actor tick with `Task { @MainActor in onCommit(style) }`. Done/Delete are
unchanged — they commit synchronously from their button actions, which are not view
updates.

## Files changed

### AtelierRefs
- `ElementInspector.swift` — `commit()` split into `commit()` + pure `builtStyle()`;
  `.onDisappear` now builds the style synchronously and defers `onCommit`.

## Migration notes

None. Behaviour is unchanged except that the outside-click commit lands one runloop
tick later (imperceptible, and it was already an async DB write downstream).

## Verify

- Space board → draw a Frame/Text → Edit → change a colour/label → click outside the
  popover → the edit persists and the Xcode console stays free of "Publishing changes
  from within view updates."

# 142 — Fix: Edit-menu Undo/Redo stuck disabled (010 · Phase 1)

## Problem

App-level undo (changelog 139) worked at the model layer (proven by `AppUndoTests`) but
was **inert in the app**: the Edit ▸ Undo / Redo items stayed greyed and ⌘Z did nothing.

Root cause: `UndoRedoCommands` reached the model via `@FocusedValue`, which supplies the
value but does **not** observe the object's `objectWillChange`. So `.disabled(!canUndo)`
was evaluated once at launch (when `canUndo` was `false`) and never refreshed when an
undoable action later registered — leaving the item disabled and the ⌘Z shortcut inert.
(In-space undo was unaffected — `SpaceView` observes its model as an `@ObservedObject`.)

## Fix

Publish the model as a focused **object** (`.focusedSceneObject(model)` in `AppShellView`)
and read it with `@FocusedObject` in `UndoRedoCommands`. `@FocusedObject` subscribes to
the model, so the command re-renders on every `undoToken` bump — the enabled state and
the "Undo Rename" / "Redo Move" titles now track the stack live. The existing
`.focusedSceneValue(\.ingestionModel)` stays (Back / Snapshot / Sort still use it).

## Files changed

- `AtelierRefs/AtelierRefs/AppShellView.swift` — add `.focusedSceneObject(model)`.
- `AtelierRefs/AtelierRefs/AtelierRefsApp.swift` — `UndoRedoCommands` uses `@FocusedObject`.

## Verification

- `xcodebuild build` → **BUILD SUCCEEDED**; `AppUndoTests` → **TEST SUCCEEDED** (model
  logic unchanged). Interactive ⌘Z behavior is not headlessly testable — please confirm
  in the running app.

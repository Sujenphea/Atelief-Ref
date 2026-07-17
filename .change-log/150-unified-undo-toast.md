# 150 — Unified "action + Undo" toast (034 P1)

## Summary

Closes theme 2 of the UX pass (fragmented feedback): the app had broad undo
support but no surface that made it visible *at the moment it matters*. Delete,
Remove-from-Folder, and Move now raise a single **"…— Undo"** toast whose button
reverses the action — surfacing the existing `⌘Z` undo as a one-click affordance.

Design mirrors the existing capture "Saved — Jump" toast (011-B4): the model
publishes a typed event, the shell observes it and posts to the shared
`ToastCenter`. The `ToastAction` enum gains an `.undo(undoToken:)` case alongside
`.jump`.

**Correctness — no wrong-undo.** `UndoManager` is a LIFO stack, so a toast can only
safely reverse the *top* action. Each toast captures the model's monotonic
`undoToken` at post time; the Undo button calls `undoLastAction(expecting:)`, which
fires **only if that token is still the stack top**. Any later action / undo / redo
bumps the token, so a superseded toast silently no-ops instead of reversing
something the user didn't mean. The toast also coalesces into one slot
(`coalesceKey: "undo-action"`), so the single visible card always describes the
action its button will reverse.

## Files changed

### AtelierRefs
- `ToastQueue.swift` — `ToastAction` gains `.undo(undoToken: Int)`.
- `ToastHost.swift` — `ToastCard` renders the Undo button + an orange undo glyph
  (green check stays for Jump); `ToastHostView` takes `onUndo` and routes both
  action cases.
- `IngestionModel.swift` — new published `lastUndoableAction` event
  (`UndoableActionEvent { message, undoToken }`); `announceUndoable(_:)` fires it
  after `registerReversible` in `removeFromFolder` / `moveToCollection` /
  `confirmPendingDeletion`; `undoLastAction(expecting:)` guards the undo by token.
- `ContentView.swift` — observes `model.lastUndoableAction` and posts the coalesced
  Undo toast; `handleUndo` routes the guarded undo.

### AtelierRefsTests
- `AppUndoTests.swift` — `undoableEventReversesViaToken` (a verb announces an event
  whose token fires the undo) and `staleUndoTokenNoOps` (a superseded toast's token
  no-ops; the live one still works).

## Migration notes

None. The transient toolbar `status` line is unchanged (kept as the passive echo);
the toast adds the actionable Undo affordance on top. Copy ("Add to") is not
registered as undoable, so it raises no Undo toast.

## Verify

- Grid → select items → Delete (confirm) → a "Deleted N — Undo" toast appears →
  click **Undo** → the items return.
- Same for right-click **Remove from Collection** and **Move to ▸**.
- Delete, then Move, then click the (now single, coalesced) toast's Undo → it
  reverses the Move (the top), not the Delete.

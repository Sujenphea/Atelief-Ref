# 303 — one undo mechanism

## Summary

`SpaceModel` and `IngestionModel` each carried their own copy of the undo
machinery — the `UndoManager`, the serial write chain, the explicit grouping, and
the recursive ping-pong that makes undo → redo → undo work. The two copies were
byte-identical apart from one renamed field (`writeChain` / `undoWriteChain`), down
to the comment on `installUndo` — `IngestionModel`'s even says *"see `SpaceModel`"*,
which is the duplication admitting itself in prose.

It is now one type, `UndoStack`, and both models hold one.

## Why this one mattered more than it looks

The ping-pong is four lines and every one of them is a trap:

```swift
manager.registerUndo(withTarget: self) { stack in
    inverse()
    stack.installUndo(name, primary: inverse, inverse: primary)   // swapped
    stack.manager.setActionName(name)                             // re-set, or redo goes unnamed
}
```

It must NOT open its own group (during undo/redo `UndoManager` supplies the
enclosing one — opening a second leaves the stack unbalanced), the two closures must
swap on re-install, and the action name has to be re-applied or the menu item reads
"Redo" with no verb. A fix to either copy left the other one wrong, silently, and
nothing in either file said the other existed.

## What moved, and what deliberately did not

`UndoStack` owns the `UndoManager` (now **private** — the models were exposing
theirs, and nothing outside either file ever touched it), the FIFO write chain, the
grouping, and the ping-pong.

The **`@Published undoToken` stays on each model.** SwiftUI observes the model, and
a nested `ObservableObject` does not propagate its `objectWillChange` to the parent —
moving the token into the stack would have quietly stopped the Edit menu and the
Space toolbar from refreshing. Instead the stack takes an `onChange` callback and
the models pass `{ [weak self] in self?.undoToken &+= 1 }`, which also collapses the
bump from three sites per model to one.

The models keep their `waitForWrites` / `canUndo` / `canRedo` / `undoActionName` /
`redoActionName` / `undo()` / `redo()` as one-line forwarders — that is the surface
11 test files and 3 views already call, and there was no reason to churn it.

## Call sites: zero changed

`registerReversible` and `enqueue`/`enqueueUndoable` kept their names and signatures
on both models, so all 18 verb registrations and 55 enqueues are untouched. The diff
is 30 lines in, 81 out.

## A stale comment, fixed

`SpaceModel`'s undo doc claimed registrations are synchronous "so `groupsByEvent`
coalesces a frame's per-tile group-move into a SINGLE undo step". `groupsByEvent` is
set to **false** twenty lines below, and the coalescing is done by `flushMoves()`
draining a burst buffer. The comment described the opposite of the code. Both facts
are now stated where the behaviour lives, in `UndoStack`'s header.

## Files changed

- `UndoStack.swift` — new.
- `SpaceModel.swift`, `IngestionModel.swift` — the mechanism deleted, forwarders in
  its place; `groupsByEvent = false` removed from all three inits (the stack's own
  init does it).

## Verified

`-only-testing:AtelierRefsTests test` → `** TEST SUCCEEDED **`, which covers
`AppUndoTests` (all seven library verbs + the stale-toast token guard), `SpaceUndoTests`,
`SpaceMultiSelectTests`' group-move coalescing, `SpaceArrangeTests`' action names, and
`HomeCardDeleteTests`' two-step undo.

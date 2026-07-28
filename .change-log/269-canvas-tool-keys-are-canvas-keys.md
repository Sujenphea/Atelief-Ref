# 269 — The tool keys move onto the canvas

## Summary

Double-click-to-edit was still failing after 266 and 268, and the cause was neither the
press path nor the editor. It was three lines in `SpaceView`:

```swift
Button("") { tool = .select }.keyboardShortcut("v", modifiers: [])
Button("") { tool = .frame  }.keyboardShortcut("f", modifiers: [])
Button("") { tool = .text   }.keyboardShortcut("t", modifiers: [])
```

A key equivalent is dispatched **before** `keyDown` reaches the first responder, and it
cannot see that the responder is an `NSTextView` living inside an `NSViewRepresentable`.
So every `t`, `f` and `v` typed into a text box was claimed by a button: the character
never arrived, and the tool changed underneath the user. Measured, not inferred — the
harness is now a test (below).

What made it read as "double-click is broken" is what happens next, because
`canvasPressTarget` opens with `if tool != .select { return .create }`:

- After an **`f`**, a click without a drag fails `finishCreate`'s minimum-size guard and
  returns *without* calling `onCreateElement` — the only place the tool resets to
  `.select`. The board is stuck in frame mode: clicks don't select, double-clicks don't
  edit, the hover cursor stops. And the tool picker only renders in the `.idle`
  selection state, so with a tile selected there is no visible way back.
- After a **`t`**, the too-small branch substitutes a default box instead, so the next
  double-click on an existing box **creates a new empty one on top of it** and edits
  that.

`t`, `f` and `v` are three of the commonest letters in English. "The" broke on its first
keystroke.

## The fix

The canvas handles them, in `keyDown`, and reports through a new
`CanvasHostView.onSelectTool`. `keyDown` only reaches a first responder, and an open
editor *is* the first responder — so the canvas's own focus is the gate, and no amount
of app-side wiring can reintroduce the collision. The mapping is a pure static
`toolShortcut(characters:modifiers:)`: bare means bare (⌘/⌥/⌃ disqualify, so ⌘V still
pastes), ⇧ is tolerated so a stray capital still works.

`SpaceView` loses `toolShortcuts` entirely and passes `onSelectTool: { tool = $0 }`.

**First responder is now armed on open.** `keyDown` needs it, and the host only took it
on `mouseDown` — so V/F/T would have been dead until the board was clicked once, where
the old shortcuts worked window-wide. `onHostReady` now makes the host first responder
on a main-actor hop (it fires from `makeNSView`, before the host is in a window).

Measuring this also turned up that ⌘Z-while-typing is broken for a related reason — a
sibling `keyboardShortcut` beating the canvas. That is a separate fix; see 270.

## Files changed

- `CanvasRenderer/.../Host/CanvasHostView.swift` — `onSelectTool`, the `keyDown` branch,
  `toolShortcut(characters:modifiers:)`
- `CanvasRenderer/.../Host/CanvasView.swift` — `onSelectTool` through the seam
- `AtelierRefs/AtelierRefs/SpaceView.swift` — `toolShortcuts` deleted, `onSelectTool`
  wired, first responder armed from `onHostReady`
- `CanvasRenderer/Tests/.../HostToolKeyTests.swift` — new, 6 cases

## Tests

Four cases cover the new code: the mapping, that a modifier disqualifies it, that a bare
key is reported and consumed, that an open edit suppresses it, and that ⌫ still deletes
the selection.

The sixth is the one that would have *found* this, and it pins the platform behaviour
the whole design now rests on: a hosted `NSTextView` takes first responder, a sibling
SwiftUI `Button` carries `keyboardShortcut("t", modifiers: [])`, and a `t` key-down goes
through `window.performKeyEquivalent` exactly as AppKit would route it. The button
claims it, its action runs, and the text view's string stays empty.

**What no test here can do** is stop someone adding an unmodified `keyboardShortcut` to
the app again — that is a property of the view tree, not of any unit under test. The
guard for that is the comment left at the deletion site in `SpaceView`.

Both suites green: 365 in `CanvasRenderer`, and `AtelierRefsTests`.

## Migration notes

`CanvasView(onSelectTool:)` is new and optional; a canvas that passes nothing simply
ignores the tool keys.

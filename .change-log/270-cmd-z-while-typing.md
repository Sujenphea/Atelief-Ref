# 270 — ⌘Z while typing undoes a keystroke, not the board

## Summary

268 moved Escape, ⌘↵ and ⌘Z into `CanvasHostView.performKeyEquivalent` and claimed all
three would then beat menu-level matching. Escape and ⌘↵ do. **⌘Z never did.** Measured
with an edit open and both present in the window, the app's undo button claims it and
the canvas is never asked — so a single ⌘Z mid-sentence reverted the whole previous
board operation, and the branch that was supposed to prevent that never ran.

## It takes both halves, and neither works alone

This is the part worth recording, because fixing only one half looks like progress and
isn't:

- **The app must stand down.** A sibling SwiftUI `keyboardShortcut` beats the host's
  `performKeyEquivalent`. `undoRedoBar` therefore withdraws its binding while
  `editingTileID != nil`.
- **But withdrawing it is not enough.** With nothing claiming ⌘Z it falls through to
  `keyDown` on the `NSTextView`, which does nothing with it — typing undo is normally
  driven by an Edit ▸ Undo menu item this app has no equivalent of. Undo has to be
  *performed*, and the host is where the open edit is known.

Withdrawing alone was briefly shipped in the working tree and made ⌘Z do nothing at all,
which is how the second half came to light. Together: the app stands down, the host
drives the text view's own undo manager, and ⌘Z undoes one keystroke.

The **buttons stay mounted and clickable** — only the key binding is withdrawn — so the
action bar doesn't reflow when an edit starts, and undo is still reachable by mouse.

## Files changed

- `CanvasRenderer/.../Host/CanvasHostView.swift` — the ⌘Z branch, documented as the
  bargain it is rather than as an unconditional guarantee
- `AtelierRefs/AtelierRefs/SpaceView.swift` — `undoRedoBar` withdraws its bindings while
  editing
- `.change-log/268-canvas-editor-in-the-host.md` — the incorrect claim corrected in place

## Verification

By hand, in a hosted canvas: type into a box, press ⌘Z, and the text reverts while the
board's undo stack is untouched. Not covered by a unit test — the failure lives in
AppKit's key-equivalent dispatch order across two sibling views in one window, which a
headless test can reproduce only by rebuilding the whole window, and did, as a probe.

# 268 — Inline text editing moves into the canvas host

## Summary

Editing a text box is a canvas gesture: it starts on a double-click, it has to stay
glued to a tile's on-screen frame through every pan, zoom, move and resize, and it has
to take first responder without racing anything. It was implemented as a SwiftUI
`NSViewRepresentable` mounted *beside* the canvas, reaching back into it through a
bridge object.

That put four asynchronous hops between the user's second click and a caret existing:

```
AppKit mouseDown → app closure → @State editingTileID → SwiftUI view update
                 → viewDidMoveToWindow → makeFirstResponder
```

During those hops the tile could move, the host could be rebuilt, or the edit could
commit itself. 266 fixed the two failures that were biting hardest; this removes the
shape that produced them.

`CanvasHostView` now owns the `NSTextView` and begins editing **synchronously inside
`mouseDown`**, where the gesture is.

## The seam

What stays in the app is policy — what a string means, when a box should be deleted,
how anything persists. The renderer asks; the app answers:

- `CanvasTextEditRequest` — a token-keyed *value*, not a method call, because the app
  drives it from SwiftUI where the same state is pushed on every update. Creating a
  text box has to wait for the row to be written before it knows the tile id, so the
  request is set once and re-delivered until consumed. `nil` is a **no-op, never an
  end**: the app clears its state after the request is taken, and that must not tear
  down the edit it just started.
- `CanvasTextEditOutcome` — `.committed(String)` / `.cancelled` / `.deleted`.
- `beginEditingText(tileID:isNewlyCreated:)`, `endEditingText(commit:)`,
  `onEditingChanged`, `onFinishEditingText`.
- `editingTileID` is now `private(set)`: the host owns the edit, so nobody else can
  claim one is in progress that isn't.

**No typography crosses the seam.** This was expected to need an app-supplied
font/colour/alignment resolver. It doesn't: `TileContent.text(TextStyle)` already
carries the string, size, colour, family, weight and alignment, and the provider hands
it across on every sync. `CanvasEngine.textStyle(forTileID:)` exposes it, so the editor
builds its glyphs from the same value the renderer draws from — and the duplicated
family/weight table the app kept (because `CanvasFont` was internal) is deleted in
favour of `CanvasFont.nsFont(family:weight:size:)`.

## Consequences

**Deleted**: `AtelierRefs/AtelierRefs/InlineTextEditor.swift` in full — the
representable, its Coordinator, `CanvasEditingBridge`, `PassThroughContainer`, and the
private `nsFont`. `SpaceView` loses `editBridge`, `editingWasNew` and the whole
`inlineEditor(tileID:itemID:)` mounting; `editingTileID` survives only as a mirror
written by `onEditingChanged`, because the format bubble targets "the box being edited".

`PassThroughContainer` is gone rather than moved. It existed to pass clicks that missed
the text box through to the canvas, because the container filled the entire canvas area.
The editor is now a subview of the host and only as large as the box itself, so a click
that misses it simply lands on the host.

**Teardown paths.** The old editor had blur / ⌘↵ / Esc / viewport-exit. Added:
`viewWillMove(toWindow: nil)` and `NSApplication.willTerminateNotification`, both
committing — losing typed text because a board was switched or a window closed is never
what the user meant. (Honest caveat, unchanged from before: `SpaceModel` writes go
through an async queue, so a commit at terminate may not reach disk.)

**Escape, ⌘↵ and ⌘Z** move to `performKeyEquivalent`, so they beat menu-level matching.
⌘Z is the subtle one: while typing, undo must be the text view's per-keystroke undo, not
the board's. The app's undo button is a SwiftUI `keyboardShortcut`, which would
otherwise swallow it and revert the whole previous board operation mid-sentence.

**Handles vs the caret.** Resize-while-editing is deliberate (262/263), so the handles
cannot simply be switched off over the edited box — but their zones reach 11pt inward
from every edge, which on a short text box leaves almost nothing for the caret.
`ResizeGeometry.editingHitSize` (10pt, vs 22) applies to the edited tile only, returning
a 6pt band top and bottom to the text while every handle stays catchable at the edge.
The cursor over the edited box is left to the text view, which vends its own I-beam.

**Ordering.** The engine's transform / live-frame fan-out repositions the editor
*before* notifying the app. The editor's height push changes the tile's displayed frame,
and the format bubble anchors on that frame — reading it first would leave the bubble a
frame behind.

## Files changed

- `CanvasRenderer/.../Host/CanvasTextEditController.swift` — new; the live editor
- `CanvasRenderer/.../Host/CanvasHostView.swift` — the seam, the lifecycle hooks,
  `performKeyEquivalent`, the cursor exception
- `CanvasRenderer/.../Host/CanvasView.swift` — `editingTileID` → `editRequest` +
  `onEditingChanged` + `onFinishEditingText`
- `CanvasRenderer/.../Host/CanvasEngine.swift` — the reduced grab zone while editing
- `CanvasRenderer/.../ResizeHandles.swift` — `editingHitSize`
- `CanvasRenderer/.../TextMetrics.swift` — `CanvasFont.nsFont(family:weight:size:)`
- `AtelierRefs/AtelierRefs/InlineTextEditor.swift` — **deleted**
- `AtelierRefs/AtelierRefs/SpaceView.swift` — mirrors the edit, applies the outcome
- `AtelierRefs/AtelierRefs/SpaceFormatChrome.swift` — the anchor holds the host directly
- `CanvasRenderer/Tests/.../HostEditingTests.swift` — new, 14 cases

## Migration notes

`CanvasView(editingTileID:)` is gone. To start an edit, pass an `editRequest` with a
fresh token; to hear about one, use `onEditingChanged` / `onFinishEditingText`.
`CanvasHostView.setEditingBoxHeight` is no longer public — the host's own editor drives
it.

A double-click on a text tile no longer needs anything from `onActivateTile`: the host
has already begun the edit by the time it fires. The callback still fires, so an app can
keep its selection in step.

Both suites green: 359 in `CanvasRenderer`, and the `AtelierRefsTests` target.

## Still open

The line-break glitch on entering edit mode. Committed glyphs are laid out by CoreText
(`TextShaper`), the editor's by TextKit (`NSTextView`), and the two break lines
differently. One engine — TextKit — for both, tracked for `.docs/063`. Note that on
macOS 26 `NSTextView` defaults to TextKit **2**, so which TextKit the renderer adopts
has to be settled before that port, not during it.

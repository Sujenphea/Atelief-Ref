# 483 — the text box learns Figma's manners

## Summary

Six divergences between a board's text box and Figma, the reference point. Five
were bugs in the sense that the board did something no one asked for; one was a
control that existed but lived two clicks from the thing it controls. They are
one entry because they are one gesture — place a text box, type in it, get out —
and fixing any of them alone leaves the gesture still wrong.

Each was confirmed with the user before it was written.

## 1 · An armed create tool now says so (crosshair)

`CanvasHostView.updateHoverCursor` returned early unless `tool == .select`, so
with Text or Frame armed the pointer stayed the plain arrow: the cursor said
*click to select* while the canvas meant *drag out a box*. That is the same
undiscoverability the resize handles were given a cursor for in 062, and it gets
the same answer — `NSCursor.crosshair` over the **whole** viewport, because
`canvasPressTarget` hands a create tool every press, over a tile or not.

The hover state went from `hoveredHandle: ResizeHandle?` to a four-case
`HoverCursor` (`arrow` / `crosshair` / `resize` / `editor`), which is what makes
"the text view owns its I-beam here" a value rather than an early `return`. And
`tool` gained a `didSet`: arming a tool moves no mouse, so without it the
crosshair waited for a jiggle. `mouseEntered` answers for the same reason.

## 2 · Auto ↔ Fixed width moved next to the box

`ElementStyle.textAutoWidth` has been real since 063 and `ElementInspector` has
had a Width control all along — behind the selection bar's "Edit style" glyph,
two layers from the box. Meanwhile a resize-handle drag silently turns hugging
**off** (`SpaceModel.resizeTile`, unchanged and correct). A state a gesture can
clear has to be visible where the gesture is, which is where Figma keeps its
resizing control too.

So the floating format bubble (062) gained a fifth segment, between align and the
colour dot. It is the bubble's only segment that **acts** rather than opening a
panel — the setting has two states, and a panel to choose between two states is a
click to reach a click. Its icon is a readout, the way the align segment's is:
`arrow.left.and.right` when the box sizes itself, the same arrow boxed in when
the user owns the width. The inspector's copy stays; both write one field.

`CanvasTextEditController.applyTypographyIfChanged` became `applyStyleIfChanged`,
because a width flip mid-edit is not typography: it moves no glyph, so it must
NOT reset the font (which resets the typing attributes), but it does change the
width `reposition()` measures against, so it must re-place the overlay. Folding
the mode into `Typography` would have done the first; ignoring it did neither,
and the live box sat at its old width until the next keystroke.

## 3 · A wide, shallow text drag keeps its width

`finishCreate` required a text rubber-band to clear `minCreateWorldEdge` in
**both** dimensions. That is right for a frame and wrong for text: a text box's
height follows its wrapped glyphs (062), so the natural gesture — sweep out the
column width you want, barely moving vertically — failed the test, was reported
as a click, and the width the user had just drawn was discarded in favour of a
hugging box at the press point.

Width alone decides it now, in `CanvasHostView.textDragChoseWidth(worldRect:)` —
pure and static, so the rule is pinned by `TextCreateGateTests` rather than by
the shape of an `if` inside a gesture no headless test can reach. Frame still
needs both.

## 4 · Esc keeps what you typed

`onEscape` mapped to `finish(commit: false)`, so ⎋ — the key people press to get
out of a mode — was the one gesture on this canvas that silently destroyed work.
In Figma it ends the edit and keeps the text, with the box selected; undo is the
way back to the old string, which is where undo belongs.

Both Esc paths now commit: the text view's own `keyDown` (the normal case) and
`CanvasHostView.performKeyEquivalent` (an edit that began before the host had a
window). A brand-new box that is Esc'd while still empty is still deleted —
`canvasTextEditOutcome` decides that from the string, not from which key ended
the edit — so the Figma behaviour falls out of the rule that was already there.

`CanvasTextEditOutcome.cancelled` is now unreachable from any key. It stays,
because `endEditingText(commit:)` is public API and "abandon this edit" is still
a coherent thing for a host to ask for.

## 5 · Esc disarms the tool

`keyDown` had no Esc branch, so an armed Text tool could only be cleared by
placing a box or pressing `V` — the user who armed it by mistake had to make the
mistake to get out of it. ⎋ now asks for `.select` and abandons any rubber-band
in flight (`cancelCreate()`), as Figma's ⎋ returns to Move.

It is gated on `tool != .select` so the key is only swallowed when it has
something to do; under Select it falls through to the responder chain, where a
sheet or popover may want it. An open edit still wins — that gate is the existing
`editingTileID` guard at the top of `keyDown`, and case 4 above is what ⎋ means
there.

## 6 · A new box is born empty

`defaultTextStyle()` seeded the literal `"Text"`, pre-selected so the first
keystroke replaced it. That reads fine if you type. Place a box and click away
without typing and the empty-box rule never fires — the string is not empty — so
the board kept a box that said "Text" and that nobody asked for.

The seed is `""` now, which routes the same abandonment through
`canvasTextEditOutcome`'s existing `.deleted` arm. Nothing collapses: `TextShaper`
shapes an empty string as a lone space, so a hugging box is born a caret's width
wide and a line tall — the sliver-with-a-caret Figma drops where you click.

## What was considered and left

**Figma's third resizing mode (Fixed size).** Height here always follows the text
(062's invariant) and there is no way to ask for a fixed height with clipped or
overflowing glyphs. Left as is, deliberately: it would touch `TextMetrics`, the
inline editor, `resizeTile` and the style schema, and the invariant it would break
is load-bearing.

**Two undo entries for an abandoned box.** Placing a box registers "Add Text" and
abandoning it registers the removal, so an abandoned placement leaves two entries
rather than none. Pre-existing (any empty commit did this), but case 6 makes it
the common path. ⌘Z resurrecting an accidentally-abandoned box is benign, so it
is noted rather than fixed.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — `HoverCursor`,
  `tool.didSet`, `mouseEntered`, `refreshHoverCursor`, `textDragChoseWidth`,
  `cancelCreate`, `isEscape`, the `keyDown` Esc branch, Esc-commits in
  `performKeyEquivalent`, the `applyStyleIfChanged` call site.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasTextEditController.swift` —
  Esc commits; `applyTypographyIfChanged` → `applyStyleIfChanged` + `appliedHugsWidth`.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasTextEdit.swift` — `.cancelled` docs.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEditorViews.swift` — docs.
- `AtelierRefs/AtelierRefs/ElementRendering.swift` — `defaultTextStyle()` seeds `""`.
- `AtelierRefs/AtelierRefs/SpaceFormatChrome.swift` — the width-mode segment and its
  layout arithmetic.
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `addText` docs.
- Tests: `PressTargetTests` (`TextCreateGateTests`), `HostToolKeyTests` (Esc disarm),
  `HostEditingTests` (renamed), `SpaceFormatChromeTests` (five segments).

## Migration notes

None. No schema change — `textAutoWidth` is the field 063 added and existing rows
are untouched. The one behaviour change a user could notice on an existing board
is ⎋: it commits now where it used to abandon.

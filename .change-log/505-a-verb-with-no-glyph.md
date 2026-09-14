# 505 — a verb with no glyph

## Summary

P2 of [100](../.docs/100-spaces-group-frame-design.md): ⌘G becomes reachable. P1
built `groupSelectionInFrame()` and left it callable from nothing; this wires the
keystroke and writes the `KeyMap` row that is now the only place a user can learn
the chord exists.

The interesting decision was whether the board's floating bar gets a button for
it, and the answer is no. [069] collapsed nine ops behind three glyphs for one
stated reason — the row is the same width in every mode, so it stops growing under
the cursor the moment a second tile is selected. ⌘G is live at two tiles and up,
so a glyph for it could only live in `multiBar`, which is exactly that defect
re-introduced by the one control whose whole subject is multi-selection. Hoisting
it mode-invariantly the way undo/redo is hoisted does not rescue it either: a
"group" button offered with nothing selected is an affordance for a verb that
cannot run. So the chord is carried by a zero-size button and the shortcuts sheet
is its discovery surface, the same deal ⌘⇧] and ⌘⇧[ already live under.

The carrier still has to be mounted in every mode, and for a sharper reason than
tidiness: a `keyboardShortcut` on a view that isn't rendered never fires, and
`barMode` is derived from the selection count, so a binding living inside
`multiBar` would be gated on the very state the chord is supposed to act upon —
present only once the selection is already big enough, absent at the moment the
count changes. Mounting it everywhere is safe because the gate is the MODEL:
`groupSelectionInFrame()` no-ops below two drawn tiles, so ⌘G on an empty or
single selection does nothing rather than something wrong. P1's no-op is what
makes this pattern available at all.

The shortcut, not the view, is withdrawn while a text box is being edited. A key
equivalent is dispatched before `keyDown` reaches the first responder, so a live
⌘G would frame the board mid-sentence — and since ⌘G means nothing to an
`NSTextView`, the keystroke would simply vanish into a new frame rather than
inserting a letter. Unmounting the carrier instead would reflow the bar mid-edit,
which is why `undoRedoBar` and `duplicateButton` both withdraw rather than
disappear.

`G` was unbound on every scope before this, chord and bare letter alike, so the
collision check went green without argument.

## Files changed

- `AtelierRefs/AtelierRefs/SpaceView.swift` — `groupInFrameShortcut`, a zero-size
  `keyboardShortcut` carrier mounted beside `zOrderShortcuts` in `actionBar`, so
  it is live in `.idle` / `.single` / `.multi` alike and withdrawn while
  `editingTileID != nil`. The doc comment carries the no-button argument, because
  the absence of a glyph is the kind of decision that looks like an oversight to
  the next reader.
- `AtelierRefs/AtelierRefs/KeyMap.swift` — the `.space` row for ⌘G, "Wrap the
  selection in a frame", `decoder: .none` (a SwiftUI binding, not a pure decoder)
  with its `source:` naming the carrier's line. The section's leading comment is
  amended: it claimed the board's remaining bare letters were free, which is true
  of `toolShortcut` but was already silently contradicted by `A` riding
  `boardShortcut` — and ⌘G spends none of that budget, since both decoders reject
  ⌘ and bare `G` is still available.

## What P2 leaves standing

The gesture is complete and silent about bystanders. A frame created at a
selection's bounding box can adopt a tile the user never picked (100 §3); the
adopted set comes back from `groupSelectionInFrame()` and this phase discards it.
P3 raises the timed wash that spends it.

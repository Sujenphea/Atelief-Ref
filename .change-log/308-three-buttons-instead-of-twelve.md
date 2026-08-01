# 308 — Three buttons instead of twelve

The Space action bar rendered **sixteen glyphs** at a multi-selection. Nine came
from one flat `ForEach` over `CanvasArrange.Operation.allCases`; the ruler,
duplicate and two z-order buttons made twelve ops in a row that already carried
undo/redo and the export pair. Selecting a second tile roughly doubled the bar's
width.

Align, spacing and z-order now sit behind **one glyph each**. Sixteen → eight, and
the bar no longer changes width or rearranges under the cursor as the selection
grows.

```
before  [↶][↷][⇤][⬌][⇥][⤒][⬍][⤓][↔][↕][▦][📏][⧉][◱][◰] │ [⤓][○]
after   [↶][↷][⇤][↔][⧉][◲] │ [⤓][○]
```

## What moved

| group | trigger | panel holds |
|---|---|---|
| align | `align.horizontal.left` | the 6 aligns, 2 rows — H above, V below |
| spacing | `arrow.left.and.right` | distribute ×2, Tidy Up, exact gap |
| z-order | `square.3.layers.3d` | Bring to Front, Send to Back |

Nothing was removed. Every op still applies the same model call.

## Decisions worth knowing

**Panels don't dismiss on apply.** Aligning is rapid-fire — align left, then align
top, then nudge — so closing after each op would cost a click per op and undo the
point of collapsing the row. The canvas updates live behind the panel; Esc or an
outside click closes it. Z-order is the exception: front and back are terminal, so
picking one closes.

**A group's trigger is live while ANY op inside would run**, not while all of them
would. At 2 selected the distributes are dead (they need 3) but Tidy Up and the gap
are not — and 2 items is exactly when someone reaches for a tidy. Gating on the
group's headline op would have buried both. The dead rows still dim *inside* the
panel, preserving the bar's existing "not yet" reading. This is the regression the
new tests pin.

**⌘⇧] / ⌘⇧[ were re-hosted.** The bindings lived on the two z-order bar buttons.
Collapsing those into a popover would have killed both shortcuts, because a
`keyboardShortcut` on an unrendered view never fires and a closed popover's content
isn't mounted at all. They now ride two zero-size buttons in the bar, mounted in
every mode — the same bargain `undoRedoBar` and `duplicateButton` already strike,
and they withdraw identically while a text box is being edited.

**Triggers are static, no chevron.** A multi-selection has no "current" alignment to
mirror, unlike the text bubble's align segment, so there is no honest state to show.
Each trigger keeps the exact weight of every other bar glyph.

**Z-order is grouped in `.single` too**, though that mode has room for both buttons.
The point is that the control doesn't move or change shape when a second tile is
selected.

**All three panels share `popoverContent()`'s default `lg` inset**, and that is a
deliberate departure from `selectionMenuChrome()`, which uses `xs` on the reasoning
that "this one's ROWS carry their own inset (they are the click targets), so a wide
outer pad would double it" — true of the align grid's glyphs and of `ZOrderRow` too.

That rule optimises for equal perceived air inside one panel. These three are used
differently: they open from adjacent buttons in one bar, so they are seen in
succession and what reads is the FRAME jumping between them. A shared inset makes
the three feel like one control with three faces, and keeps them in step with the
app's seven other `lg` popovers.

The trade is accepted, not overlooked: content that carries its own margin is padded
twice, so align and z-order sit airier than the spacing form. The note on
`SpaceBarGroup` records this so the next reader doesn't revert one panel to `xs`
citing the rule and reintroduce the frame jump.

**Z-order got its own rows.** It briefly wore `SelectionMenuRow` +
`selectionMenuChrome()`, which look like the right reuse and are only half right.
That row's leading inset is `Spacing.sm + (indent + 1) * 8` — indentation math for
the nested destination tree in `CollectionView`'s overflow — landing on 16pt leading
against 8pt trailing in a panel with no tree to indent. The chrome also pins 220pt so
nested lists line up, which two fixed rows have nothing to line up against.
`ZOrderRow` is symmetric and the panel is content-sized (~150pt).

## Fixed in passing

066's gap popover used `arrowEdge: .bottom`, opening *downward* into the floating
capsule — `CollectionView` documents `.top` as the correct choice for a bar popover
for exactly this reason. All three panels now use `.top`.

## Migration notes

- `SpaceGapPopover.swift` → `SpaceSpacingPopover.swift`. The type gained
  `selectionCount` and an `onArrange` callback; `onApply` is now `onPack`. The file's
  reasoning about *why* a focusable field must live in a popover (bugs 269, 271) is
  unchanged and still applies.
- The gap field **no longer auto-focuses on open**. It was the only control in 066's
  popover, so focusing it was free; the panel now leads with Distribute, and stealing
  focus would put a cursor in an unrelated field every time someone opens it for Tidy
  Up. Clicking the field still works and still holds focus safely.
- `SpaceView.symbol(for:)` moved to `SpaceArrangeSymbols.symbol(for:)` so the bar and
  the panels read one table.
- `SpaceView.zOrderBar` is gone, replaced by `groupButton(.zOrder)` +
  `zOrderShortcuts`.
- `SpaceBarGroup` is main-actor isolated, following `CanvasArrange` rather than
  `SpaceBarMode`. `SpaceBarMode` can afford `nonisolated` only because it reads
  nothing but an `Int`; this reads `minimumCount` off every child op.

## Files changed

- `AtelierRefs/SpaceArrangeGroups.swift` — new: `SpaceBarGroup`,
  `SpaceArrangeSymbols`, `ArrangeGlyphButton`, `SpaceAlignPopover`,
  `SpaceZOrderPopover`, `ZOrderRow`
- `AtelierRefs/SpaceSpacingPopover.swift` — was `SpaceGapPopover.swift`
- `AtelierRefs/SpaceView.swift` — `singleBar`, `multiBar`, `groupButton`,
  `groupPanel`, `popoverBinding`, `restoreCanvasFocus`, `zOrderShortcuts`; dropped
  `gapButton`, `zOrderBar`, `symbol(for:)`
- `AtelierRefs/Theme.swift` — doc reference to the renamed type
- `AtelierRefsTests/SpaceBarModeTests.swift` — 5 new tests: the groups partition
  every op, a trigger is live iff a child is, spacing survives at 2, the per-group
  floors, distinct glyphs

Full suite green.

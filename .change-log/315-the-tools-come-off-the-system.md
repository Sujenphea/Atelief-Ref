# 315 — the board's tools come off the system

## Summary

The Spaces action bar's Select / Frame / Text control was a stock
`Picker(...).pickerStyle(.segmented)` — an AppKit-drawn bezel with an **accent-tinted**
live segment, sitting inside `selectionBarChrome()`'s monochrome capsule of flat glyphs.
`Theme.swift`'s own header says it plainly: *"Monochrome by design … There is NO coloured
accent."* This was the last coloured chrome the app drew.

`307` took every popover off the system and built `SegmentedControl` as the token
replacement; `312` did the detail page. Neither reached the board's bar. This closes it,
and sweeps the two remaining stock pickers out of the debug window with it.

### Why not just reuse `SegmentedControl`

Because its marker is wrong here, and `DialogControls`'s header already says why:
selection is an **outline** in a popover *"because the card is already `surface` and a
second raised grey reads as a third layer"* — while *"a sidebar row, a chip and a
floating bar all mark 'active' with a raised `field` / `selection` fill."*

The action bar is the second case. An outlined segment in there would be the drift, not
the consistency. Its geometry is wrong too: `SegmentedControl` spaces at `sm` (8) with
8/6 insets, where the bar is `spacing: 2` around 30×28 glyphs — the tools would have been
the one child of the row out of rhythm, which is the defect being fixed.

So the tools become three bar glyphs, and `SelectionBarModeButton` is the named home for
a MODE row wearing the bar's vocabulary. The two idioms are documented against each
other in both files so a future reader can't mistake this for a third segmented look.

### The `barSeparator` loses half its reason

Its doc justified itself twice — semantically (an export *leaves* the app) and
geometrically (the picker's bezel is a hard edge with none of a 15pt glyph's ~7.5pt of
own air, so the export button looked jammed against it at `spacing: 2`). The tools are
`SelectionBarIcon` glyphs now and carry that air like everything else, so the geometric
defect is gone. The rule stays on the semantic reason alone; its comment now records
that rather than claiming a fix it no longer performs.

## Files changed

- `AtelierRefs/AtelierRefs/SelectionActionBar.swift` — `SelectionBarIcon` gains `isOn`,
  which takes the raised `Theme.Colors.selection` fill and steps the hover fill aside
  beneath it. New `SelectionBarModeButton`: a glyph that reports a mode rather than
  firing an action, `inkPrimary` when live and `inkSecondary` when not (**not** the
  `0.35` the bar uses for *disabled* — an inactive tool is one click away, not
  unavailable), carrying `.isSelected` for VoiceOver.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — `toolPicker` rebuilt as an
  `HStack(spacing: 2)` of three `SelectionBarModeButton`s on `Theme.Motion.gentle`.
  Per-tool tooltips ("Select (V)" / "Frame (F)" / "Text (T)") replace the single
  combined one a lone control was limited to. `barSeparator`'s doc updated.
- `AtelierRefs/AtelierRefs/Debug/GridBakeoffWindow.swift` — the Mode and Wrappers
  pickers move onto `SegmentedControl` with explicit `Text` labels (the title the
  `Picker` used to draw for itself, in the same idiom as the neighbouring "Duration"
  field). A debug surface is still not a second design system.
- `AtelierRefs/AtelierRefs/DialogControls.swift` — header records the bake-off switches
  as `SegmentedControl` clients, and why the board's tools deliberately are not.

`.pickerStyle(.segmented)` now appears **nowhere** in the app but in prose.

## Migration notes

None — presentation only. `CanvasTool`, the `$tool` binding, `onCreateElement`'s
flip-back-to-Select and the V/F/T key handling in the canvas's `keyDown` (269) are all
untouched. The shortcuts never lived on this control (051 · E-2) precisely so they keep
firing when a selection swaps the tools out of the bar, and that is unchanged.

## Verify

- Open a board, deselect everything → the bar's tool row is three 30×28 glyphs at the
  same rhythm as undo/redo and the export, with **no blue** anywhere and no bezel.
- The live tool wears the raised `selection` grey; the other two are `inkSecondary` and
  legible, not dimmed to the disabled `0.35`.
- Hover an inactive tool → `hoverControl` wash. Hover the active one → the selection
  fill holds; the pointer doesn't wash the marker out.
- Each glyph has its own tooltip. Press V / F / T with the canvas focused → the marker
  follows, and typing `v` inside a text box still types a `v` (269 unchanged).
- Rubber-band a frame → the marker snaps back to Select on its own.
- The rule before the export still sits between the tools and it, and the export no
  longer reads as jammed against the tool row.
- **Not covered by tests** — presentation only; no suite asserts on this bar. Verified
  by build, not by assertion.

## Not done

- The property is still called `toolPicker` though there is no `Picker` left in it. It
  is the name every comment in the file refers to (`barMode`'s `.idle` case, the V/F/T
  note, `barSeparator`'s doc); renaming it is a churn-only edit and is left.
- `Debug/GridBakeoffWindow.swift`'s controls row is otherwise still stock — a default
  push button, a bare `TextField`, `Divider()`. Only the two segmented pickers were in
  scope here; taking the whole window onto `DialogControls` is a separate pass.

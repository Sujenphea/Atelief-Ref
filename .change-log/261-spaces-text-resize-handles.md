# 261 — Spaces: text resize handles; the resize mode is gone

A text box could not be resized. There were no handles anywhere on the canvas, so
the only width control was a three-way mode picker in the inspector popover — and
none of its options meant "wrap to a width I choose". Text now follows Nook's rule:
**the user owns the width, the height is always derived from the text.**

Design: [.docs/062](../.docs/062-spaces-text-resize-design.md).

## What was broken

| mode | behaviour | outcome |
| --- | --- | --- |
| `.fixed` (**the default**) | `autosizedFrame` returned `nil` | box never grew → text truncated with `…` |
| `.autoWidth` | shaped with `maxWidth: nil` | one runaway line, never wrapped |
| `.autoHeight` | width frozen at `item.w` | correct, but the width was set at create time and unreachable after |

`.fixed` was the default (`ElementStyle.resize` fell back to it), so every new box
truncated. And since neither the editor nor `TextRenderLayer` clips, overflowing
text spilled visibly while typing and was only cut on commit.

## The fix

**One behaviour, no mode.** `autosizedFrame` freezes `x`/`y`/`w`, measures through
`TextMetrics` (→ `TextShaper`, the same shaping the canvas draws with) at
`w − 2·padding`, and returns a frame differing only in height. It runs after every
text and style edit, and `addText` derives the height at create time — so the box
always fits its content and **truncation is now unreachable**.

**Handles**, so the width is actually settable. Eight of them on a single selected
text tile. The geometry splits two spaces on purpose, the same discipline 060
settled for glyphs:

- **hit-testing in SCREEN space** (22pt grab / 8pt dot) — a world-space grab zone
  would shrink with the box and become unhittable when zoomed out;
- **the resulting frame in WORLD space** — that is what gets persisted.

Corners are tested before edges so the overlap resolves to the corner. The live
resize mirrors the drag path (transient frame, provider untouched until mouse-up)
and recomputes from the frame captured at `beginResize`, so a long drag can't drift.

`resizeTile` treats the dragged origin + **width** as authoritative, re-derives the
**height**, and writes both as ONE undo step named "Resize".

## Files changed

- `CanvasRenderer/ResizeHandles.swift` (new) — `ResizeHandle` + `ResizeGeometry`:
  placement, screen-space hit-test, world-space resize arithmetic with clamping
- `CanvasRenderer/Host/CanvasEngine.swift` — live-resize state, `resizeHandle(at:)`,
  `begin`/`update`/`current`/`endResize`, handle-dot chrome, `displayWorldFrame`
  honours the live frame; handles gated to a single selected `.text` tile
- `CanvasRenderer/Host/CanvasHostView.swift` — `onResizeTile`; handle press takes
  precedence over a body drag; hover cursors via a tracking area
  (`NSCursor.frameResize` on macOS 15+, axis cursors below — the package targets 14)
- `CanvasRenderer/Host/CanvasView.swift` — threads `onResizeTile`
- `AtelierCore/Domain/SpaceItem.swift` — `TextResize` deleted; `resizeMode` kept as
  a legacy unread field so older rows still decode and round-trip
- `AtelierRefs/SpaceModel.swift` — `autosizedFrame` simplified; `resizeTile` (new);
  `addText` fits the created height
- `AtelierRefs/SpaceContent.swift` — `setPlacement` takes optional `w`/`h`
- `AtelierRefs/InlineTextEditor.swift` — `inlineEditorWorldBox` loses its mode
- `AtelierRefs/ElementInspector.swift` — the Resize picker is gone
- `AtelierRefs/SpaceView.swift` — wires `onResizeTile`
- Tests: `ResizeHandleTests` + `EngineResizeTests` (new, 30 tests);
  `SpaceTextResizeTests` + `SpaceInlineEditGeometryTests` rewritten;
  `ElementStyleTextTests` + `ServicesSpaceStylePlacementTests` updated

## Verification

`swift test` (CanvasRenderer) — **246 tests in 29 suites** green.
`swift test` (AtelierCore) — **549 tests in 82 suites** green.
`xcodebuild test -only-testing:AtelierRefsTests` — **TEST SUCCEEDED**.

The load-bearing assertions: the box always ends up exactly as tall as its wrapped
text (truncation unreachable); `x`/`y`/`w` never move except through `resizeTile`;
a resize is one undo step restoring both dimensions; a grab zone at 0.1× zoom still
catches its handle (the screen-vs-world regression); and the editor's layout box is
still byte-identical across 0.25×–8×.

## Migration

Boxes previously stored as `.fixed` and silently truncated will **grow downward on
first load** to reveal their full text. That is the fix working, but it re-flows
already-placed boards. `resizeMode` values are preserved in storage, just unread.

## Outstanding — manual check

**Not yet performed:** grab each handle on a selected text box and confirm the drag
feels accurate (the cursor changes on hover, the box follows the pointer, the
opposite edge stays pinned), that narrowing re-wraps and re-fits the height on
mouse-up, and that ⌘Z restores the previous width and height in one step.

## Known gaps

- **Handles are text-only** — a selected image or frame shows none, which is
  visibly inconsistent. Images need an aspect lock; frames need a rule for their
  contents. `isResizable` is the one place to change.
- **No snapping or ⇧ aspect lock** on resize (Nook has both);
  `ResizeGeometry.resizedFrame` is the seam where they would go.
- The floating format bubble + one-click colour palette from Nook remain unported.

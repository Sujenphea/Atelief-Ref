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

## Follow-up — live preview (same commit series)

Reported after the first pass: the handles and the text didn't update during a
drag. One root cause, in `setGlyphOverlay`, which shaped against
`tile.worldFrame.size` — the **stored** size. That was deliberate in 060 (keep the
`ShapeKey` off the camera) but it meant a resize left the glyphs laid out for the
old width for the whole drag: the box moved under text that refused to reflow.

Fixed by shaping against `displayWorldFrame(for:).size`. That is still pure world
arithmetic — stored frame, or the live gesture's — so the camera still cannot reach
the key and 060's zoom-invariance holds; only a deliberate resize moves it.

The second half: `updateResize` now runs the dragged rect through `fittedFrame`,
re-deriving a text tile's HEIGHT from the re-wrapped text on every tick. Previously
the height only settled on mouse-up, so narrowing a box made the text wrap onto more
lines while the box kept its old height — which is what made the handles look
frozen. The preview now can't disagree with the commit, and a vertical drag on a
text box is inert by construction (the height is the text's, never the pointer's).

**Tests added.** The original suite asserted `resizeHandle(atScreenPoint:)` followed
the live frame — the HIT-test — which passed while the drawn chrome was stale. The
gap is now closed by `resizeHandlePositions` (where dots are actually drawn) and a
`live chrome` suite: dots track the live box, the text re-wraps to more lines mid-
drag with a genuinely different `ShapeKey`, the text layer's frame follows, a
vertical drag doesn't set the height, and ending restores the provider's geometry.

CanvasRenderer: **251 tests in 30 suites** green.

## Follow-up — snapping, ratio lock, and handles for every kind

**Handles now reach images and frames.** This was the prerequisite, not scope creep:
aspect lock is meaningless on text, because `fittedFrame` overrides a text box's
height with the text's, so ⇧ would have done nothing at all. Each kind answers a new
width in one place rather than in the gesture — text re-derives its height, an image
holds its ratio **permanently** (a distorted photograph is never what the user
meant), and a frame takes the rect as given, its contents keeping their positions.

**⇧ locks any tile's ratio. ⌘ turns snapping off** — the same escape the move
gesture offers.

**Snapping** pulls a dragged edge onto a nearby box's edge or centre, with a guide
line showing why. Two rules carry it:

- the threshold is **6 SCREEN points** divided by the zoom, so "a few points" means
  the same thing to the hand at every zoom — a fixed world radius would be unusably
  sticky zoomed out and imperceptible zoomed in;
- a **ratio-locked** snap can't move the point without breaking the ratio, so the
  frame is scaled uniformly about its anchor instead, and only the single nearest
  snap applies (two would need two scales).

Candidates are the **visible** tiles minus the resized one — snapping to a box you
can't see reads as the drag sticking for no reason, and a box that snapped to its
own edge could never be nudged. A snap never breaches the minimum size.

## Files changed (follow-up)

- `CanvasRenderer/ResizeSnapping.swift` (new) — `SnapGuide`, screen-relative
  threshold, `snapPoint`, `snapAspectFrame`
- `CanvasRenderer/ResizeHandles.swift` — `keepRatio`/`aspect` on `resizedFrame`;
  `aspectRect`
- `CanvasRenderer/Host/CanvasEngine.swift` — `isResizable` opens to every kind;
  `locksAspect` for images; `updateResize(constrainRatio:snapping:)`; guide layers
- `CanvasRenderer/Host/CanvasHostView.swift` — passes ⇧ / ⌘
- Tests: `ResizeSnappingTests` (new, 15); snapping + ratio cases in
  `EngineResizeTests`; a non-text resize case in `SpaceTextResizeTests`.
  Three pre-existing tests asserted an exact total sublayer count as a proxy for
  "one highlight" — a selected tile now carries handle layers too, so they assert
  `selectionHighlightCount == 1` directly, which is what they meant.

CanvasRenderer: **273 tests in 31 suites** green. `AtelierRefsTests`: TEST SUCCEEDED.

## Still outstanding

The manual check above is unchanged and now also covers ⇧ (ratio held), ⌘ (snapping
off), and dragging an image (never distorts). Moves still don't snap — only resizes
do — and resizing a frame doesn't carry its contents even though *dragging* one
does, so those two gestures disagree.

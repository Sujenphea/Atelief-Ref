# 260 — Spaces: inline editor lays out in world space

Editing text was jerky: the page appeared to adjust its zoom, and the editor's
text "changed size magically" mid-edit. The cause was the same layout/zoom
coupling [060](../.docs/060-spaces-text-render-design.md) removed from the canvas,
still present in the editor. This moves the editor's zoom off the font and onto a
scaling container, so its layout is computed once in world units.

Modelled on Nook's Easel editor (`ref/Nook`), which solved this and documents our
exact symptoms as the reason it avoided our approach.

## Why it was jerky

`InlineTextEditor` sized the `NSTextView`'s FONT to `worldSize × zoom` and
re-applied it on every transform change. Two consequences:

1. **TextKit re-laid-out on every zoom step.** Changing a font's point size is a
   layout input, so each frame of a pinch re-ran line breaking — expensive (hence
   jerky) and free to re-wrap, which is precisely the reflow 059 filed against the
   canvas. The canvas had been fixed; the editor was the last place still coupled.
2. **The scale intermittently reverted.** `NSTextView` rewrites its own bounds
   during layout, so a scale applied to the text view does not reliably survive —
   the glyphs snap back to unscaled mid-edit. That is the "text zoom changes
   magically" symptom.

## The fix

Layout happens in WORLD units and the zoom is applied exactly once, by a view the
text system does not manage:

- **`EditorScaleBox`** (new, flipped `NSView`) sits between the pass-through
  container and the text view. Its `frame` is the tile's screen rect and its
  `bounds` is the same box in world units, so its scale *is* the camera's.
- The `NSTextView` fills those world-sized bounds at scale 1, with a **world-unit**
  `textContainerInset` and a **zoom-free** font at the style's world point size.
- `inlineEditorWorldBox(...)` (new, pure) is the geometry decision, extracted so the
  zoom-independence is directly assertable. `scale` appears in it only to map the
  tile's screen frame back to world units.

Also zeroes `lineFragmentPadding`. TextKit defaults it to 5pt, which `TextMetrics`
knows nothing about — so the editor wrapped ~10pt narrower than the committed box
measured, and a line could break differently the moment you started typing.

## Files changed

- `AtelierRefs/InlineTextEditor.swift` — `EditorScaleBox`; `inlineEditorWorldBox`;
  `reposition()` in world units; `applyFontScale()` deleted and `nsFont` returned
  to a world point size; `lineFragmentPadding = 0`; a note on the plain-text-before-
  font ordering trap (toggling `isRichText` off resets the font)
- `AtelierRefsTests/SpaceInlineEditGeometryTests.swift` (new) — 9 tests

## Verification

`swift test` (CanvasRenderer) — 216 tests in 27 suites green.
`xcodebuild test -only-testing:AtelierRefsTests` — green, including the new suite.

The crux test asserts the world layout box is **byte-identical across
0.25×–8×** in all three resize modes, plus that the `.autoHeight` wrap width is
zoom-invariant — the property that stops TextKit re-wrapping mid-pinch. Others
cover per-mode geometry, height tracking the text, degenerate/zero scale, an empty
string, and that `EditorScaleBox`'s frame÷bounds ratio equals the zoom.

## Outstanding — manual check

Live editing is not headlessly testable. **Not yet performed:** edit a text tile
while zooming and confirm the text no longer jumps or resizes on its own, and that
line breaks hold entering and leaving edit mode at a non-1.0 zoom.

## Notes

Editor and canvas still use different engines — TextKit here, CoreText in
`TextRenderLayer`. Both now lay out at the same world size against the same world
width, so they agree far more closely than before, but Nook concluded the two
"can't be made to agree" and uses TextKit for both. If a wrap mismatch shows up at
an edit boundary, that is the decision to revisit; the 060 changelog already lists
TextKit's orphan-avoiding line-break strategy as a known difference.

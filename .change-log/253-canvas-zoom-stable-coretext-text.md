# 253 — Canvas: zoom-stable CoreText text (060 / 061)

Wrapped text on the canvas **reflowed while zooming**: whole lines re-broke at
different points and appeared to jump. This replaces the per-tile `CATextLayer`
with a shape-once / draw-scaled CoreText layer, so line breaking happens once in
world space and zoom only changes the rasterization resolution.

Implements [060](../.docs/060-spaces-text-render-design.md) via the four steps of
[061](../.docs/061-spaces-text-render-plan.md); reopens and settles decision D2 of
[053](../.docs/053-spaces-text-overview.md).

## Why it reflowed

`CATextLayer` fuses layout and rasterization behind one property, `fontSize`. The
render path set `fontSize = worldFontSize × transform.scale` every frame, so every
frame re-ran line breaking at a new point size — and CoreText advances are not
exactly proportional to point size (per-size kerning, subpixel rounding), so each
re-layout broke wrapped lines slightly differently. The geometry was never wrong;
the *coupling* was. Crispness is what forced the relayout that caused the reflow.

## What replaces it

**Layout once, in world space.** `TextShaper.shape` breaks lines with
`CTFramesetter` at the world font size and world box width. It takes **no scale
argument at all**, so a layout is a pure function of `(string, fontSize, family,
weight, alignment, worldWidth, worldHeight)`. Zoom is not among them, which is
why a zoom cannot re-break a line — not "does not", *cannot*.

**Draw scaled.** `TextRenderLayer` holds that cached layout and rasterizes it at
the current zoom. Same breaks, new resolution: crisp *and* stable, which the old
path could only trade off against each other.

**One source for measure and draw.** `TextMetrics.size` (the 2C auto-size helper)
is now a thin wrapper over the same shaping call, and the size it returns is
derived from the very lines that get drawn — so a measured line break can no
longer differ from a drawn one, by construction rather than by discipline.

This is macOS-specific and sound *because* CoreText renders unhinted with
fractional glyph positioning: its metrics are linear in point size, so a layout
shaped at world size and drawn through a scaled CTM is what a re-shape would have
produced. Hinted stacks (Windows, FreeType, Android) round advances to the pixel
grid and would need extra work for the same guarantee.

## Files changed

**New**
- `CanvasRenderer/Sources/CanvasRenderer/TextShaper.swift` — `ShapedText`,
  `ShapedLine`, `ShapeKey`, memoized world-space shaping, shape-time truncation
- `CanvasRenderer/Sources/CanvasRenderer/TextRenderLayer.swift` — the drawing layer
- `CanvasRenderer/Tests/CanvasRendererTests/TextShaperTests.swift` (14 tests)
- `CanvasRenderer/Tests/CanvasRendererTests/TextRenderLayerTests.swift` (13 tests)
- `CanvasRenderer/Tests/CanvasRendererTests/EngineGlyphOverlayTests.swift` (15 tests)

**Changed**
- `TextMetrics.swift` — `size()` delegates to the shaper; `caAlignment` deleted
- `Host/CanvasEngine.swift` — `textLayers` is now `[Int: TextRenderLayer]`;
  `setGlyphOverlay` + `clampedTextFrame` replace the `CATextLayer` branch;
  `textLayer(forTileID:)` returns the new type and is internal (a test hook no app
  caller used)
- `Tests/…/EngineVectorTests.swift` — the two overlay-styling tests now read the
  font and alignment off the shaped run instead of layer properties
- `Tests/…/CanvasBenchmark.swift` — new text gate; two pre-existing bugs fixed
  (below)

## Decisions worth knowing

**Truncation happens at shape time, not draw time.** The ellipsis cut point is
pure world geometry, so it is computed once and cached. The token is built with
the same world-size attributes as the run it ends (it inherits nothing), and a
token wider than the box falls back to the untruncated line instead of dropping it.

**Scale goes in the CTM, never the text matrix.** The text matrix applies per
glyph, so scaling it would grow the letters without moving the lines apart. Glyph
outlines are y-up, so an inverted CTM would *mirror* them — the zoom therefore
goes into a positive uniform CTM scale and the top-left→baseline flip is done
arithmetically per line. `CTLineDraw` mutates the text matrix, so it is reset
before every line. A flipped incoming context (the host view is flipped) is
normalized to y-up first; a test renders both ways and compares.

**Colour is not part of the layout.** Colour cannot move a line break, so it stays
out of the `ShapeKey` and is applied as the context fill
(`kCTForegroundColorFromContextAttributeName`). A recolour costs no re-shape.

**The shaping box comes from the tile's world size**, never from the screen frame
divided by scale. Both are algebraically equal, but routing through screen space
would fold camera float-noise into the key — and a key that moves with the camera
is the exact coupling being removed here.

**Frame labels subtract no pad when shaping.** Their inset is a *screen* pad (054
§4.4) whose world equivalent shrinks as you zoom in, so folding it in would make
label shaping zoom-dependent. Labels get zoom-stability; the cost is that a very
long label meets the backing store's edge a few points sooner than before.

**Backing-store cap.** A text box zoomed deep enough is far larger than the screen,
and a layer's backing store is a GPU texture (~8192 px/side on the low end, memory
∝ zoom²). Layers bigger than the viewport plus slack are clamped, with a world
offset moving the *window* rather than the layout. Ordinary zooms are never
clamped, so pans still re-rasterize nothing.

## Accepted quality caveats

Recorded decisions, not regressions — none affects layout stability:

- **SF `trak`/`opsz`.** The system font bakes size-dependent tracking and optical
  size (Text vs Display cuts) in at the world point size, so text zoomed far in
  carries small-size letterforms rather than a native large-size cut. This is the
  same trade Figma makes.
- **Emoji are bitmap (`sbix`).** Strike selection follows the font's point size,
  not the CTM, so emoji soften at deep zoom while vector glyphs stay crisp. A
  later fix can draw colour-glyph runs with an effective-size font at the cached
  world positions.
- **Editor handoff.** `NSTextView` (TextKit) applies an orphan-avoiding line-break
  strategy `CTFramesetter` lacks, so a rare one-word wrap difference can appear at
  edit start/end. Already contained by the 2B blank-while-editing rule.

## Verification

`swift test` — **213 tests in 26 suites green**; `xcodebuild` on the macOS app
target succeeds against the changed package.

Benchmark (`CanvasBenchmark.testGlyphTextWithinBudgetAcrossZooms`), a worst-case
board of 400 overflowing text boxes with ~144 on screen, swept across zooms so
**every frame re-rasterizes** (the adversarial case; a pan re-rasterizes nothing):

| | per frame |
|---|---|
| engine sync | 0.467 ms |
| rasterize all 144 overlays | 2.464 ms |
| **total** | **2.931 ms** |
| budget (120 fps) | 8.33 ms |

Before/after on the comparable half — engine sync over the same board — was
0.442 ms on `CATextLayer` vs 0.467 ms now (+0.025 ms). The old path's raster cost
is not measurable from a test (it happens inside Core Animation) but included a
full re-layout per frame, which is the work this change deletes outright.

Two **pre-existing** benchmark bugs were fixed in passing, both of which had been
silently voiding their own assertions:
- `testVectorElementsWithinBudget` asserted `> 50` active layers at a zoom that
  only ever produced ~30, so it failed on the base commit. Zoom lowered to 0.25.
- its pan loop used a constant `+3` y-step, drifting 720 points over 240 frames and
  walking the board off the viewport — the tail of the run measured an empty scene.
  Both axes now oscillate, and a post-run assertion pins that content stayed in view.

## Outstanding — manual check

Live pinch-zoom crispness is the one surface no headless test covers (061 "Test
posture"). **Not yet performed:** open a board with an overflowing text tile and
pinch through several zoom levels, confirming glyphs stay sharp and lines do not
re-break. Everything else in the plan's test posture is automated and green.

## Migration notes

None for data — no schema change, no domain type crosses into the renderer.

For renderer callers: `CanvasEngine.textLayer(forTileID:)` now returns
`TextRenderLayer?` instead of `CATextLayer?` and is internal rather than public.
No app-layer code used it. `TextAlignment.caAlignment` is gone with the
`CATextLayer` path. Rollback, if the live check goes badly, is a revert of the
Step 4 commit (which restores the flag and the old path) or of the whole series.

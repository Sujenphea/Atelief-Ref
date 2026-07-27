# 059 — Spaces Text Rendering: Zoom-Stable Text (reopening D2)

> Direction (user, 2026-07-27): overflow (wrapped) text **visibly reflows/moves
> while zooming**. Investigation pinned the cause; the user asked "what does Figma
> do", then chose to **scope the Figma-grade fix as its own design doc**. This is
> that overview (synthesis + decision + roadmap). No code yet.
>
> This **reopens decision D2** of [053](./053-spaces-text-overview.md) ("keep the
> native `CATextLayer` render path"). D2 was correct for Phase 2's scope; the
> zoom-stability requirement is what changes the calculus.

## The symptom

When a `.text` box holds more text than fits (wrapped / overflowing), zooming makes
the text **reflow** — whole lines re-break at different points and appear to jump.
Single-line / auto-sized text (no wrap points) looks stable. Images look stable.

## Root cause (verified)

`CATextLayer` **fuses layout and rasterization** behind one property, `fontSize`.
The render path re-derives both from the live zoom every frame:

- `CanvasEngine.setTextOverlay` runs for every visible `.text` tile on every
  `sync()` (`CanvasEngine.swift:478–510`); a pinch calls `sync()` per event.
- It sets `text.fontSize = worldFontSize × transform.scale` (`:499`) and
  `text.frame` from the tile's screen rect (`:508`), with `isWrapped = true` +
  `truncationMode = .end` (`:489–490`).

The geometry is provably uniform — `worldToScreen` is `screen = world × scale +
translation` (`CanvasTransform.swift:47`), so container-width and font size scale
together and the width/font **ratio is scale-invariant**. Ideal typesetting would
therefore break every line identically at every zoom. It doesn't, because CoreText
glyph metrics are **not exactly proportional to point size** (hinting, subpixel /
integer advance rounding, per-size kerning). So each re-layout at a new `fontSize`
re-breaks wrapped lines slightly differently → reflow. `truncationMode = .end`
adds churn (the "…" cut point shifts per size). Because the frame math is uniform,
this is **not** a coordinate bug — it is layout coupling.

**Load-bearing decision behind it:** the per-frame `fontSize × scale` is *deliberate*
— it re-rasterizes crisply at any zoom. Crispness is exactly what forces the
relayout that reflows. Crisp-vs-stable, currently pinned to crisp.

## What Figma does

Figma (custom C++ engine → WebAssembly, WebGL) **separates layout from raster**:

1. **Layout once, in document space.** Shaping, kerning, and **line breaking** are
   computed at the element's document font size, producing fixed glyph positions in
   document coordinates. This step is **independent of zoom**.
2. **Zoom is a camera transform.** Drawing multiplies those fixed positions by the
   view scale — glyphs move/scale as one rigid unit, so **wrap points can never
   shift** (layout was never re-run for the viewport).
3. **Crispness via a glyph atlas.** Glyphs are rasterized from outlines at ~on-screen
   size *independently of position* — re-rasterize for resolution, **never** relayout.

Positions are zoom-invariant; only rasterization resolution tracks zoom. Reflow is
structurally impossible.

## The decision

**Reopen D2: move the `.text` (and frame-label) render path off `CATextLayer` to a
CoreText "shape-once, draw-scaled" layer.** Layout is computed once in world space
(cached, invalidated only by text/style/width changes — never by zoom); each frame
draws the cached layout scaled to the current zoom, re-rasterizing crisply without
relayout. This is the macOS-native equivalent of Figma's model.

### Why now (not "do nothing" or the transform-scale approximation)

| Option | Stability | Crisp while zooming | Effort | Verdict |
|---|---|---|---|---|
| **Do nothing** | reflows | crisp | none | rejected — the reported bug |
| **A — gesture transform-scale** (bracket the pinch, scale the `CATextLayer` rigidly, re-rasterize on end) | stable | **soft during the pinch** (bitmap-scaled) | small | good stopgap; not Figma-grade |
| **B — CoreText shape-once + draw-scaled** (this doc) | stable | **crisp** | medium–large, renderer hot path | **chosen** |

Option A is a genuine, cheap improvement (reuses the `beginDrag`/`endDrag` pattern)
and remains a valid fallback if B's per-frame draw cost proves unacceptable. B is
the correct fix and, as a bonus, is the **same path** needed for letter-spacing /
line-height (excluded in 053) — so it also unblocks that if ever wanted.

## Architecture sketch (to be specified in the design doc)

- **One layout source of truth.** A CoreText shaping helper shapes a `TextStyle`
  into a cached `CTFrame` / `[CTLine]` at the **world** font size + world box width.
  The 2C measurement helper (`TextMetrics.size`) already shapes text to measure —
  fold both onto the *same* shaping call so measured layout ≡ drawn layout (extends
  the D4 "one measurement source" rule to cover drawing too).
- **`TextRenderLayer: CALayer`** (replaces the per-tile `CATextLayer`, still outside
  the `LayerPool`, still keyed by tile id). Holds the cached layout; `draw(in:)`
  scales the context by the current zoom and `CTFrameDraw`s. `setNeedsDisplay()` on
  zoom (resolution changed); **no** cache rebuild on zoom (positions fixed).
- **Dependency direction preserved.** CanvasRenderer stays domain-free; the existing
  `TextStyle` seam already carries family/weight/alignment (2A). CoreText is a
  system framework — no new package deps.
- **Inline editor unchanged in kind** — it stays an `NSTextView` overlay
  ([054](./054-spaces-text-design.md) §5); its font mapping can share the same
  family/weight resolution.

## Performance (the gate)

Text is drawn on the CPU each frame during zoom — but `CATextLayer` **already**
re-rasterizes every frame today, so the per-frame cost is comparable, now **without
the relayout**. Mitigations: `contentsScale`, `drawsAsynchronously`, redraw only
text layers whose on-screen size actually changed, and cache the shaped layout
across frames. The engine is **benchmark-gated (~4.6 ms/frame)** — B lands only
behind a green bench on a worst-case board (many overflowing text tiles).

## Risks

- Draw-path correctness vs. `CATextLayer`: vertical origin (flipped host),
  `.left/.center/.right` alignment, end-truncation, retina crispness, emoji / colour
  glyphs, bidi/RTL. Each needs a characterization test against the current output.
- Per-frame CPU draw at high tile counts (the perf gate above).
- Scope creep into letter-spacing/line-height — keep those **out** unless explicitly
  pulled in; B only makes them *possible*.

## Roadmap (phased; full sequencing in the plan doc)

1. **Shaping helper + unify with `TextMetrics`** — one CoreText shaping call feeds
   both measure and (future) draw; zoom-invariance characterization tests (wrap
   points identical across scale ∈ {0.5, 1, 2, 4}).
2. **`TextRenderLayer` behind a flag** — swap `setTextOverlay` to it; parity +
   crispness + benchmark tests; `CATextLayer` still available for rollback.
3. **Remove the `CATextLayer` path** — delete the flag; frame labels move over too.
   (Optional, separate) letter-spacing / line-height once the seam exists.

## Test posture

- **Zoom-invariance** (the crux): shaped line breaks / glyph origins are identical
  across zoom levels — a pure test on the shaping helper (no window).
- **Parity**: drawn inset / alignment / truncation match the `CATextLayer` baseline
  (characterization).
- **Benchmark**: worst-case overflowing-text board stays under the frame budget.

## Follow-ups

If approved, next artifacts (per the docs workflow): `060-spaces-text-render-design.md`
(the spec) and `061-spaces-text-render-plan.md` (the build plan). The stopgap Option A
can ship independently at any time and is compatible with — not wasted by — B.

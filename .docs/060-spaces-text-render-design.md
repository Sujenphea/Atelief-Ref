# 060 — Spaces Text Rendering: Design (Zoom-Stable CoreText)

> The spec for [059](./059-spaces-text-render-overview.md). Replaces the per-tile
> `CATextLayer` with a CoreText **shape-once / draw-scaled** layer so wrapped text
> never reflows on zoom (Figma's model). Grounded in the current render +
> measurement code. No DB schema change; no domain type crosses into the renderer.

## Invariant (the whole point)

**Line breaking is computed once, in world space, and never re-run for the
viewport.** Zoom changes only the rasterization scale, not the layout. Formally:
for a fixed `(string, fontSize, family, weight, alignment, worldWidth)`, the set of
line breaks and per-glyph world origins is a pure function **independent of
`transform.scale`**. This is the property the crux test pins (§7).

Why this is sound on macOS specifically: CoreText renders **unhinted with
fractional glyph positioning**, so its metrics are linear in point size — a layout
shaped at world size and drawn scaled is geometrically identical to a re-shape at
the scaled size. Hinted stacks (Windows/FreeType/Android) round advances to pixels
and would need extra work (Skia's `LINEAR_TEXT_FLAG`); we get linearity for free.

## 1. Shaping — one layout source of truth

Extend the existing single-source helper (`CanvasRenderer/TextMetrics.swift`, which
today already shapes via `NSAttributedString.boundingRect`) with a CoreText
framesetter that both **measures** and **draws** from the SAME shaping call — so a
drawn line break can never differ from a measured one (extends D4 to cover drawing).

```
struct ShapedText {              // value type, Equatable by its inputs' cache key
    let lines: [ShapedLine]      // top-to-bottom, world coordinates, top-left origin
    let size: CGSize             // world-space tight size (ceil), == TextMetrics.size
    let lineHeight: CGFloat      // ascent + descent + leading, world
}
struct ShapedLine {
    let line: CTLine             // shaped run (already width-broken)
    let origin: CGPoint          // world, TOP-LEFT-relative: x = alignment offset,
                                 // y = distance from the box top to this baseline
}
```

- `TextShaper.shape(_ style: TextStyle, maxWidth: CGFloat?, maxHeight: CGFloat? = nil) -> ShapedText`
  - Font: `CanvasFont.resolve(family:weight:)` copied to the world `fontSize`
    (`CTFontCreateCopyWithAttributes`) — unchanged from `TextMetrics.size`.
  - Paragraph style: alignment (`.left/.center/.right`), `lineBreakMode` word-wrap.
  - `CTFramesetterCreateWithAttributedString` → `CTFramesetterSuggestFrameSize…`
    for `size`; `CTFramesetterCreateFrame` over a rect of `width = maxWidth ?? suggested`,
    tall height → `CTFrameGetLines` + `CTFrameGetLineOrigins`, converted to
    **top-left** origins (`y = boxTop - originFromBottom`).
  - `maxWidth == nil` ⇒ unconstrained single measure (autoWidth / `.fixed` one-liner);
    a value ⇒ wrapped (autoHeight / overflow `.fixed`).
  - **Truncation happens here, at shape time** (not at draw). When `maxHeight` is
    given (overflow `.fixed`), the last line that fits is replaced with
    `CTLineCreateTruncatedLine(…, .end, ellipsisToken)` and cached in `lines` —
    the cut point is pure world geometry, so it is zoom-stable and computed once.
    The ellipsis token is a CTLine built with the SAME world-size attributes as
    the run it ends (it inherits nothing); a `nil` result (token wider than the
    box) falls back to the untruncated line. `maxHeight == nil` (all measurement
    callers) skips truncation entirely.
- **`TextMetrics.size(for:maxWidth:)` becomes a thin wrapper** returning
  `shape(...).size`. It stays `public` (2C callers unchanged). The measured size may
  differ from today's `boundingRect` by ≤1px on some strings — acceptable: the 2C
  tests assert **bounded + monotonic**, not exact pins ([055](./055-spaces-text-plan.md)
  §4), and measure≡draw is now guaranteed by construction.
- **Memoize** shaped results by `ShapeKey(string, fontSize, family, weight,
  alignment, maxWidthBucket, maxHeightBucket)` (bounded like `CanvasFont.cache`; a
  board carries few distinct texts). Zoom is NOT in the key — that is the invariant.

`TextShaper` stays `@MainActor`, CoreText/AppKit only — CanvasRenderer remains
domain-free (the `TextStyle` seam already carries family/weight/alignment, 2A).

## 2. `TextRenderLayer: CALayer` — draw the cached layout, scaled

Replaces the per-tile `CATextLayer` (still **outside** the `LayerPool`, still keyed
by tile id in `textLayers`).

- Stores the cached `ShapedText` + its `worldWidth` (the box content width it was
  shaped against) + the world padding policy. Setting a **new** `ShapedText`
  (style/text/width changed) is the only thing that invalidates layout.
- `needsDisplayOnBoundsChange = true`. The engine sets the layer's `frame` to the
  tile's screen rect every `sync()` (as today); a zoom changes `bounds` ⇒ one
  `draw(in:)` at the new resolution — **re-rasterized crisp, same line breaks**.
- `draw(in ctx:)`:
  1. `scale` is set by the engine (`drawScale = transform.scale`), NOT derived as
     `bounds.width / worldContentWidth`: an auto-width box or a frame label is
     narrower than the layer it sits in, so a derived ratio would overscale those.
  2. **Scale the CTM, not the text matrix — but keep the CTM's y POSITIVE.** The
     text matrix applies per glyph; line origins go through the CTM, so scaling
     the text matrix would grow letters without moving lines apart. The obvious
     `scaleBy(scale, −scale)` "flip to top-left" is *wrong* though: glyph outlines
     are y-up, so a negative-y CTM mirrors every glyph. Instead apply a **positive
     uniform** `ctx.scaleBy(scale, scale)` (context is now world units, y-up) and
     flip baselines arithmetically in step 3. A context that arrives already
     flipped (`ctx.ctm.d < 0`, which is what CoreAnimation hands a layer inside
     the flipped host view) is normalized to y-up first.
  3. For each `ShapedLine`: `ctx.textMatrix = .identity` (reset per line —
     `CTLineDraw` mutates it), `ctx.textPosition = (line.origin.x,
     worldHeight − line.origin.y)` in world units, `CTLineDraw(line, ctx)`. Glyph
     outlines rasterize through the scaled CTM at `worldFontSize · scale` (crisp)
     while positions come from the cached layout (stable). The pad is not added
     here — the engine already inset the layer's frame by it.
  4. **No truncation here** — the end-ellipsis is baked into the cached
     `ShapedText` at shape time (§1); `draw(in:)` only draws cached lines. (Also:
     never `CTFrameDraw` — it draws line-over-line, which mis-stacks shadows if
     any effect is ever added.)
- `contentsScale = max(1, backingScale)` (retina), as today.
- **Backing-store cap:** the layer's frame is the tile's screen rect, which at deep
  zoom can exceed the GPU texture ceiling (8192–16384 px/side — silent degradation
  past it, ~zoom² memory before it). The engine clamps the layer to the
  tile ∩ viewport rect (offsetting the drawn world origin by the clipped amount) so
  the backing store never materially exceeds screen size.

**Vertical anchoring:** top-left, matching `CATextLayer`'s default — the first
baseline sits at `top + scale · ascent`. A parity test pins this against the current
output at zoom ∈ {0.5, 1, 2, 4}.

## 3. Engine wiring (`CanvasEngine.setTextOverlay`)

`setTextOverlay` keeps its shape and call sites (`sync()` `.text` :373 and
`.frame` label :365), but:

- Resolves/caches a `ShapedText` for the tile (via `TextShaper`) when the style or
  the world content width changed; otherwise reuses the cached layout.
- Sets `layer.frame = screenFrame.insetBy(pad)` exactly as today — `pad =
  TextMetrics.padding × scale` for `.text` (world-padded), the legacy screen pad for
  frame labels (§4.4 unchanged).
- Does **not** touch a `fontSize` property (there is none now); the scale is implied
  by `bounds`. The `worldPadded` flag and the whole padding-reconciliation contract
  (054 §4.4) are preserved.
- The `editingTileID` blank-while-editing rule (2B) is unchanged: a nil style tears
  the layer down.

The `textLayers` dict type changes `CATextLayer → TextRenderLayer`; the
`textLayer(forTileID:)` test accessor returns the new type.

## 4. What stays the same

- **World↔screen** math, `displayWorldFrame`, drag/pan/zoom paths — untouched
  (the frame is still uniform-affine; only the layer's *content* draw changes).
- **Auto-size (2C)** — `TextMetrics.size` is still the measurement API; its result is
  now literally the shaped size (measure≡draw by construction).
- **Inline editor (2B)** — still an `NSTextView` overlay; unaffected in kind. Its
  font mapping already mirrors `CanvasFont`; no change required. (Its own glyphs are
  live-edited, not zoom-critical.)
- **`FrameStyle.label`** text renders through the same `TextRenderLayer` (frames get
  zoom-stable labels for free).

## 5. Performance

- `draw(in:)` fires on bounds change — the **same cadence** `CATextLayer` re-rasters
  today, minus the relayout. Net per-frame work should be ≤ today.
- Mitigations: `drawsAsynchronously = true` (note: `draw(in:)` still runs on the
  main thread — CA only executes the queued commands on its own thread); skip
  `setNeedsDisplay` when the on-screen size is unchanged (pan-only frames don't
  re-raster text); shaped-layout cache across frames; `CTLine`s retained in
  `ShapedText`.
- **Benchmark-gated (~4.6 ms/frame).** Lands only behind a green bench on a
  worst-case board (many overflowing text tiles) at several zooms.
- **Fallback ladder if the bench fails** (in order, before shipping any regression):
  1. **Background pre-raster** — CoreText is documented thread-safe (framesetting +
     `CTLineDraw` into an owned `CGBitmapContext` off-main is Apple's own
     CATiledLayer contract); render tiles to `CGImage`s on a queue and swap
     `layer.contents`. Keeps crisp-while-zooming, moves the cost off-frame.
  2. **Banded `contentsScale`** — re-raster only when zoom crosses a ×2 band,
     transform-scale between bands (the Chromium pattern; Nook's Easel ships it).
     Bounds both redraw frequency and memory.
  3. **Option A** — gesture-bracketed transform scale, re-raster at rest (059).

## 6. Risks / parity checklist

Each verified against the current `CATextLayer` output (characterization):
top-left vertical origin · `.left/.center/.right` alignment offsets · end-truncation
ellipsis · retina crispness · empty-string one-line height · emoji / colour glyphs ·
bidi/RTL (at least no regression) · frame-label parity (screen-pad path).

**Accepted quality caveats** (recorded decisions, not regressions):

- **SF `trak`/`opsz`:** the system font bakes size-dependent tracking + optical
  size (Text/Display cuts) at the world point size, so text zoomed far in carries
  small-size letterforms/tracking rather than a native large-size cut. Layout
  stability is untouched. This is the trade Figma makes; Nook's Easel ships the
  same unnoticed. Accepted.
- **Emoji are bitmap (`sbix`):** strike selection follows the font's point size,
  not the CTM, so emoji soften at deep zoom while vector glyphs stay crisp (plus a
  known ±1px size wobble in scaled contexts — Apple forums 751191). Accepted; a
  later fix can draw colour-glyph runs with an effective-size font at the cached
  world positions.
- **Editor handoff:** NSTextView (TextKit) applies an orphan-avoiding line-break
  strategy that `CTFramesetter` lacks, so a rare one-word wrap difference can show
  at edit start/end. Already contained by blank-while-editing (2B); disabling the
  editor's default line-break strategy closes it further if it ever bothers.

## 7. Test surface

- **Zoom-invariance (crux, pure):** `TextShaper.shape` line count, per-line `origin`,
  and break positions are **identical** across `fontSize`-vs-`worldWidth` pairs that
  represent the same content at different zooms — i.e. shaping does not depend on any
  scale (there is no scale input). Pin line breaks for an overflowing string.
- **measure≡draw:** `TextMetrics.size == shape(...).size` for a matrix of strings /
  widths / weights.
- **2C regression:** the existing `TextMetricsTests` bounded/monotonic assertions
  still hold against the framesetter size.
- **Parity (renderer):** rendered inset / alignment / truncation match the baseline
  at zoom ∈ {0.5, 1, 2, 4} (extends the §4.4 draw≡measure characterization).
- **Benchmark:** worst-case board under budget.

## 8. Non-goals

Letter-spacing / line-height stay **out** (053 exclusion). This design only makes
them *possible* (the shaping seam is where they'd attach). Do not add them here.

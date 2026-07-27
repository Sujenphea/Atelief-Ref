# 061 — Spaces Text Rendering: Implementation Plan

> The build plan for [059](./059-spaces-text-render-overview.md) /
> [060](./060-spaces-text-render-design.md). Zoom-stable CoreText text. Each step is
> independently buildable + testable and lands as its own commit; nothing changes
> the DB schema, and CanvasRenderer stays domain-free throughout.
>
> **Behind a flag until Step 4** so the `CATextLayer` path is a one-line rollback
> the whole time.

## Step 1 — Shaping helper + unify measurement

**Files:** `CanvasRenderer/.../TextMetrics.swift` (or a new `TextShaper.swift` beside
it), `CanvasRenderer/Tests/CanvasRendererTests/…`.

- Add `TextShaper.shape(_ style: TextStyle, maxWidth: CGFloat?, maxHeight:
  CGFloat? = nil) -> ShapedText` (`CTFramesetter`; top-left line origins; alignment
  + word-wrap paragraph style; same font construction as today). Memoize by
  `ShapeKey` (no scale in the key).
- **Truncate at shape time**: with a `maxHeight`, the last fitting line becomes
  `CTLineCreateTruncatedLine(…, .end, token)` cached in `lines` — the token built
  with the same world-size attributes (it inherits none); `nil` result (token wider
  than box) falls back untruncated. Draw never truncates (060 §2).
- Rewrite `TextMetrics.size(for:maxWidth:)` as `shape(...).size` — one source for
  measure and (Step 2) draw.

**Tests** (`CanvasRendererTests`): **zoom-invariance** — shaping has no scale input,
so line breaks / origins for an overflowing string are pinned once and are what draw
uses; **measure≡draw** — `size == shape(...).size` across a string/width/weight
matrix; the existing `TextMetricsTests` bounded/monotonic assertions still pass
against the framesetter size (adjust only brittle exact pins, none should exist);
**truncation** — with a `maxHeight` the last fitting line carries the ellipsis,
the cut point is a pure function of world geometry, and a token wider than the box
falls back to the untruncated line (no crash, no dropped line).

## Step 2 — `TextRenderLayer` (drawn but not yet wired)

**Files:** new `CanvasRenderer/.../TextRenderLayer.swift`, tests.

- `TextRenderLayer: CALayer` holding a `ShapedText` + `worldContentWidth`;
  `needsDisplayOnBoundsChange = true`; `draw(in:)` puts flip + zoom in the **CTM**
  (`scale = bounds.width / worldContentWidth`; never the text matrix — it applies
  per glyph, not to line origins), resets `textMatrix = .identity` per line
  (`CTLineDraw` mutates it), draws cached lines at world origins; truncation is
  already baked into `ShapedText` (Step 1); `contentsScale = max(1, backingScale)`,
  `drawsAsynchronously = true`.

**Tests** (`CanvasRendererTests`, headless CGContext): draw into a bitmap at scale
{0.5, 1, 2, 4} and assert — first-baseline top-anchor, alignment offsets
(left/center/right ink bounds), truncation ellipsis appears when overflowing, empty
string → one line height. Assert **positions scale uniformly** (a glyph's world
origin × scale == its drawn origin) — the anti-reflow guarantee at the pixel level.

## Step 3 — Wire into the engine behind a flag

**Files:** `CanvasRenderer/.../Host/CanvasEngine.swift`.

- `textLayers: [Int: TextRenderLayer]`; `setTextOverlay` resolves/caches a
  `ShapedText` (rebuild only on style / world-width change), sets `layer.frame =
  screenFrame.insetBy(pad)` exactly as today (world-pad vs screen-pad preserved),
  calls `setNeedsDisplay()` only when the on-screen size changed.
- **Backing-store cap** (060 §2): clamp the layer to the tile ∩ viewport rect at
  deep zoom (offset the drawn world origin by the clipped amount) so the backing
  store never exceeds the GPU texture ceiling (8192 px/side floor).
- Gate behind `CanvasEngine.useCoreTextGlyphs` (default **off**) so the
  `CATextLayer` path stays for rollback; `textLayer(forTileID:)` returns the active
  type.

**Tests** (`CanvasRendererTests`): with the flag on — overlay attach/detach parity
(count, blank-while-editing for `editingTileID`, recycle on viewport exit); pan-only
frames do **not** call `setNeedsDisplay` (spy); a zoom does.

**→ Commit A: `feat: canvas - zoom-stable CoreText text layer (flagged)`**

## Step 4 — Flip the default, drop `CATextLayer`, benchmark

**Files:** `CanvasEngine.swift`, benchmark target, changelog.

- Default the flag **on**; delete the `CATextLayer` branch + `caAlignment` usage once
  no caller remains. Frame labels ride the new layer too.
- **Benchmark** a worst-case board (N overflowing text tiles) across zooms; confirm
  ≤ the ~4.6 ms/frame budget. If it regresses, keep the flag and step down the 060
  §5 fallback ladder instead of shipping a regression: (1) background pre-raster
  (CoreText is thread-safe off-main; render tiles to `CGImage`s on a queue, swap
  `layer.contents`), (2) banded `contentsScale` (re-raster only on ×2 band cross —
  the Chromium/Nook pattern), (3) the Option-A transform-scale stopgap (059).

**Tests:** full `CanvasRendererTests` green; benchmark recorded in the changelog with
before/after frame times. Parity characterization (inset / alignment / truncation at
zoom ∈ {0.5,1,2,4}) promoted to the default path.

**→ Commit B: `feat: canvas - CoreText text default; remove CATextLayer path`**

## Test posture

Every pure/headless surface is covered: shaping zoom-invariance, measure≡draw, the
2C size regression, the layer draw at multiple scales (top-anchor / alignment /
truncation / uniform-position), engine attach-detach + redraw-cadence parity, and
the benchmark. The only non-headless surface is subjective crispness during a live
pinch — recorded in the changelog as a manual check.

## Risk / sequencing notes

- Steps 1–2 are additive and fully headless; Step 3 is additive behind a flag; Step
  4 is the only removal and is **benchmark-gated**.
- If Step 4's bench fails, ship Steps 1–3 (flagged off) plus the **Option A**
  stopgap and revisit — no wasted work (A and B compose, 059).
- Do **not** fold with the unrelated in-flight `200-item-detail` / dist workstreams.
- Letter-spacing / line-height remain OUT (053); the shaping seam merely makes them
  reachable later.

## Changelog

One entry per commit under `.change-log/` (`feat: canvas - …`), files-changed +
verification. Commit B's records the benchmark before/after and the live-crispness
manual check.

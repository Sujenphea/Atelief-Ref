//
//  TextRenderLayer.swift
//  CanvasRenderer
//
//  060 §2 — draws a cached world-space layout, scaled. Replaces the per-tile
//  `CATextLayer`, whose one `fontSize` property FUSED layout and rasterization:
//  feeding it `worldFontSize × zoom` re-ran line breaking every frame, and because
//  CoreText advances aren't exactly proportional to point size, wrapped lines
//  re-broke slightly differently at each zoom — the reflow 059 reported.
//
//  Here the two are separate. The layout arrives pre-shaped (``ShapedText``,
//  world units, never re-broken); a zoom changes only ``drawScale``, so the SAME
//  line breaks rasterize at the new resolution. Crisp AND stable, not either/or.
//
//  Coordinate handling is the fiddly part, so it is spelled out:
//  · Glyph outlines are y-UP. Inverting the CTM's y (the usual "flip to top-left"
//    move) would mirror them, so the zoom goes into a POSITIVE uniform CTM scale
//    and the top-left→baseline flip is done arithmetically, per line.
//  · Scale belongs in the CTM, never the text matrix: the text matrix applies per
//    glyph, so scaling it would grow the letters without moving the lines apart.
//  · `CTLineDraw` MUTATES the text matrix, so it is reset before every line.
//

import CoreGraphics
import CoreText
import QuartzCore

/// A tile's text overlay: one cached world-space layout, rasterized at the
/// current zoom. Lives OUTSIDE the recycling ``LayerPool`` (decision T3), keyed by
/// tile id, exactly as the `CATextLayer` it replaces did.
final class TextRenderLayer: CALayer {

    /// The cached world-space layout. Setting a layout with a DIFFERENT
    /// ``ShapeKey`` is the only thing that invalidates line breaking — and zoom
    /// can never produce one, because scale is not part of the key.
    private(set) var shaped: ShapedText?

    /// World → screen scale (the engine's `transform.scale`). Set explicitly
    /// rather than derived from `bounds ÷ contentWidth`: an auto-width box or a
    /// frame label is narrower than the layer it sits in, so a derived ratio
    /// would silently overscale those.
    var drawScale: CGFloat = 1

    /// Glyph colour. Deliberately NOT part of the layout — colour can't move a
    /// line break, so a recolour must not cost a re-shape. Applied as the
    /// context's fill (the shaped runs carry
    /// `kCTForegroundColorFromContextAttribute`).
    var textColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

    /// World-space offset of the layer's top-left from the text box's top-left.
    /// Non-zero only when the engine clamps an enormous deep-zoom layer to the
    /// viewport (060 §2 backing-store cap): the layout stays put, the window onto
    /// it moves.
    var worldOffset: CGPoint = .zero

    /// Draw calls served — headless introspection for the redraw-cadence tests
    /// (a pan must not re-rasterize text; a zoom must).
    private(set) var drawCount = 0

    override init() {
        super.init()
        // A zoom changes the on-screen size → exactly the moments a re-raster is
        // needed. A pan only moves `position`, so it draws nothing.
        needsDisplayOnBoundsChange = true
        // Text is opaque ink on a transparent tile; no implicit fade on content
        // changes (the tile beneath would show through mid-animation).
        actions = ["contents": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull()]
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? TextRenderLayer {
            shaped = other.shaped
            drawScale = other.drawScale
            textColor = other.textColor
            worldOffset = other.worldOffset
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Adopt a layout, redrawing only when it is genuinely a different one.
    /// Returns whether a redraw was scheduled (the engine's cadence assertions
    /// read this).
    @discardableResult
    func setShaped(_ next: ShapedText) -> Bool {
        guard shaped?.key != next.key else { return false }
        shaped = next
        setNeedsDisplay()
        return true
    }

    /// Apply the per-frame draw state, redrawing only if something visible moved.
    /// `drawScale` is the zoom; a pan leaves every argument unchanged, so a
    /// pan-only frame schedules nothing.
    @discardableResult
    func apply(scale: CGFloat, color: CGColor, worldOffset offset: CGPoint) -> Bool {
        let changed = drawScale != scale || textColor != color || worldOffset != offset
        guard changed else { return false }
        drawScale = scale
        textColor = color
        worldOffset = offset
        setNeedsDisplay()
        return true
    }

    override func draw(in ctx: CGContext) {
        drawCount += 1
        guard let shaped, !shaped.lines.isEmpty,
              bounds.width > 0, bounds.height > 0, drawScale > 0 else { return }

        // CoreAnimation hands a flipped context when the host view is flipped
        // (``CanvasHostView.isFlipped`` is true). Glyphs are y-up, so normalize to
        // a y-UP space first and do the top-left flip in arithmetic below —
        // rather than leaving an inverted CTM, which would mirror every glyph.
        if ctx.ctm.d < 0 {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }

        ctx.setFillColor(textColor)
        // The zoom, and ONLY the zoom, lives here. Positions below stay in world
        // units, so the cached layout is what gets drawn — just at a new
        // resolution. Glyph outlines rasterize at `worldFontSize × drawScale`.
        ctx.scaleBy(x: drawScale, y: drawScale)

        // The layer's height in world units — the datum the top-left baselines
        // flip against.
        let worldHeight = bounds.height / drawScale
        for line in shaped.lines {
            // `CTLineDraw` leaves the text matrix modified; reset per line.
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(
                x: line.origin.x - worldOffset.x,
                y: worldHeight - (line.origin.y - worldOffset.y))
            CTLineDraw(line.line, ctx)
        }
    }
}

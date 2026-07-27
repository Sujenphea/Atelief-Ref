//
//  TextRenderLayerTests.swift
//  CanvasRendererTests
//
//  060 §7 · 061 Step 2 — the draw half of the anti-reflow guarantee, asserted at
//  the PIXEL level. Everything here renders the layer into a headless
//  `CGBitmapContext` and reads the ink back, so there is no window, no timing,
//  and no subjective "looks crisp" judgement.
//
//  The crux test is `positionsScaleUniformly`: one cached layout drawn at
//  0.5× / 1× / 2× / 4× must produce ink whose geometry is a pure multiple of the
//  1× ink. If a zoom could still re-break a line, the band count or the ink
//  extent would drift instead of scaling — which is exactly the bug 059 reported.
//

import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import CanvasRenderer

// MARK: - Headless ink capture

/// The alpha channel of a rendered layer, in BUFFER row order (row 0 = visually
/// top), so "the first line sits near the top" reads literally.
private struct InkMap {
    let width: Int
    let height: Int
    private let alpha: [UInt8]

    init(width: Int, height: Int, alpha: [UInt8]) {
        self.width = width
        self.height = height
        self.alpha = alpha
    }

    /// Ink = meaningfully opaque, so antialiasing fringes don't count as edges.
    func hasInk(x: Int, y: Int) -> Bool { alpha[y * width + x] > 32 }

    func rowHasInk(_ y: Int) -> Bool { (0..<width).contains { hasInk(x: $0, y: y) } }

    var isEmpty: Bool { !(0..<height).contains { rowHasInk($0) } }

    /// Tight bounding box of the ink, in buffer coordinates.
    var bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where hasInk(x: x, y: y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }

    /// Contiguous runs of inked rows — one per rendered line of text (given a
    /// font size where the interline gap actually clears).
    var rowBands: [ClosedRange<Int>] {
        var bands: [ClosedRange<Int>] = []
        var start: Int?
        for y in 0..<height {
            if rowHasInk(y) {
                if start == nil { start = y }
            } else if let s = start {
                bands.append(s...(y - 1)); start = nil
            }
        }
        if let s = start { bands.append(s...(height - 1)) }
        return bands
    }
}

/// Render a layer into a fresh bitmap and read back its ink.
///
/// `preFlipped` reproduces the context CoreAnimation hands a layer inside a
/// flipped host view (``CanvasHostView/isFlipped``): the same drawing must come
/// out identical, which is what the layer's y-up normalization exists for.
@MainActor
private func render(_ layer: TextRenderLayer, preFlipped: Bool = false) -> InkMap {
    let width = Int(layer.bounds.width.rounded(.up))
    let height = Int(layer.bounds.height.rounded(.up))
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let ctx = data.withUnsafeMutableBytes { raw in
        CGContext(
            data: raw.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    guard let ctx else { return InkMap(width: 0, height: 0, alpha: []) }
    if preFlipped {
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
    }
    layer.draw(in: ctx)
    // Alpha is the last byte of each premultiplied RGBA pixel.
    var alpha = [UInt8](repeating: 0, count: width * height)
    let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<(width * height) { alpha[i] = bytes[i * 4 + 3] }
    return InkMap(width: width, height: height, alpha: alpha)
}

@MainActor
@Suite("TextRenderLayer draw (060 §2 · scaled, never re-laid-out)")
struct TextRenderLayerTests {

    private func style(_ string: String, fontSize: Double = 20,
                       alignment: TextAlignment = .left) -> TextStyle {
        TextStyle(string: string, fontSize: fontSize,
                  color: RGBAColor(red: 0, green: 0, blue: 0),
                  alignment: alignment)
    }

    /// A layer holding `shaped`, sized to the world box at `scale`.
    private func layer(_ shaped: ShapedText, worldSize: CGSize, scale: CGFloat) -> TextRenderLayer {
        let l = TextRenderLayer()
        l.setShaped(shaped)
        l.drawScale = scale
        l.bounds = CGRect(x: 0, y: 0, width: worldSize.width * scale, height: worldSize.height * scale)
        return l
    }

    private let wrapping = "The quick brown fox jumps over the lazy dog"
    private let worldWidth: CGFloat = 200

    // MARK: - The crux: one layout, many resolutions

    @Test("positions scale uniformly across zoom — the anti-reflow guarantee in pixels")
    func positionsScaleUniformly() {
        let shaped = TextShaper.shape(style(wrapping), maxWidth: worldWidth)
        let world = CGSize(width: worldWidth, height: shaped.size.height)
        #expect(shaped.lines.count > 1)

        let base = render(layer(shaped, worldSize: world, scale: 1))
        guard let baseBox = base.bounds else { Issue.record("no ink at 1×"); return }
        let baseBands = base.rowBands.count

        for scale in [CGFloat(2), 4] {
            let ink = render(layer(shaped, worldSize: world, scale: scale))
            guard let box = ink.bounds else { Issue.record("no ink at \(scale)×"); return }

            // Same number of drawn lines: a re-break would change this.
            #expect(ink.rowBands.count == baseBands)

            // Every ink edge is the 1× edge times the scale — the whole layout
            // moved as one rigid body.
            let tolerance = max(CGFloat(3), 0.04 * scale * CGFloat(baseBox.maxX))
            #expect(abs(CGFloat(box.minX) - CGFloat(baseBox.minX) * scale) <= tolerance)
            #expect(abs(CGFloat(box.minY) - CGFloat(baseBox.minY) * scale) <= tolerance)
            #expect(abs(CGFloat(box.maxX) - CGFloat(baseBox.maxX) * scale) <= tolerance)
            #expect(abs(CGFloat(box.maxY) - CGFloat(baseBox.maxY) * scale) <= tolerance)
        }
    }

    @Test("a half-scale draw keeps the layout, just smaller")
    func minifiesWithoutReflow() {
        let shaped = TextShaper.shape(style(wrapping), maxWidth: worldWidth)
        let world = CGSize(width: worldWidth, height: shaped.size.height)
        let full = render(layer(shaped, worldSize: world, scale: 1))
        let half = render(layer(shaped, worldSize: world, scale: 0.5))
        guard let fullBox = full.bounds, let halfBox = half.bounds else {
            Issue.record("missing ink"); return
        }
        // Ink shrinks by ~half in each axis (bands may merge at 0.5×, so only the
        // extent is asserted here — band counts are covered at ≥ 1×).
        #expect(abs(CGFloat(halfBox.maxX) - CGFloat(fullBox.maxX) * 0.5) <= 4)
        #expect(abs(CGFloat(halfBox.maxY) - CGFloat(fullBox.maxY) * 0.5) <= 4)
    }

    @Test("the drawn line count equals the shaped line count at every zoom")
    func drawnLinesMatchShapedLines() {
        let shaped = TextShaper.shape(style(wrapping), maxWidth: worldWidth)
        let world = CGSize(width: worldWidth, height: shaped.size.height)
        for scale in [CGFloat(1), 2, 4] {
            let ink = render(layer(shaped, worldSize: world, scale: scale))
            #expect(ink.rowBands.count == shaped.lines.count)
        }
    }

    // MARK: - Anchoring + orientation

    @Test("text is top-anchored: the first line's ink starts near the box top")
    func topAnchored() {
        let shaped = TextShaper.shape(style(wrapping), maxWidth: worldWidth)
        let world = CGSize(width: worldWidth, height: shaped.size.height)
        for scale in [CGFloat(1), 2, 4] {
            let ink = render(layer(shaped, worldSize: world, scale: scale))
            guard let box = ink.bounds else { Issue.record("no ink"); return }
            // Ink begins within the first line's box, not floating mid-layer.
            #expect(CGFloat(box.minY) < shaped.lineHeight * scale)
            // …and the last line's ink ends within the last line's box.
            #expect(CGFloat(box.maxY) > (shaped.size.height - shaped.lineHeight) * scale - 2)
        }
    }

    @Test("glyphs render upright in a flipped context, identically to a y-up one")
    func flippedContextRendersTheSame() {
        let shaped = TextShaper.shape(style(wrapping), maxWidth: worldWidth)
        let world = CGSize(width: worldWidth, height: shaped.size.height)
        let upright = render(layer(shaped, worldSize: world, scale: 2))
        let flipped = render(layer(shaped, worldSize: world, scale: 2), preFlipped: true)
        guard let a = upright.bounds, let b = flipped.bounds else {
            Issue.record("missing ink"); return
        }
        #expect(a.minX == b.minX && a.maxX == b.maxX)
        #expect(a.minY == b.minY && a.maxY == b.maxY)
        #expect(upright.rowBands.count == flipped.rowBands.count)
    }

    // MARK: - Alignment

    @Test("alignment moves the ink: left hugs the leading edge, right the trailing")
    func alignmentPlacesInk() {
        let text = "short"
        let width: CGFloat = 300
        func inkBox(_ alignment: TextAlignment) -> (minX: Int, maxX: Int) {
            let shaped = TextShaper.shape(style(text, alignment: alignment), maxWidth: width)
            let l = layer(shaped, worldSize: CGSize(width: width, height: shaped.size.height), scale: 2)
            guard let box = render(l).bounds else { return (0, 0) }
            return (box.minX, box.maxX)
        }
        let left = inkBox(.left), center = inkBox(.center), right = inkBox(.right)
        #expect(left.minX < center.minX)
        #expect(center.minX < right.minX)
        // Left starts at the leading edge; right ends at the trailing edge.
        #expect(left.minX < 8)
        #expect(right.maxX > Int(width * 2) - 12)
    }

    // MARK: - Truncation (baked in at shape time — the layer just draws it)

    @Test("an overflowing box draws only the fitting lines, with ellipsis ink")
    func truncationDrawsFittingLines() {
        let long = "The quick brown fox jumps over the lazy dog again and again and again"
        let full = TextShaper.shape(style(long), maxWidth: worldWidth)
        #expect(full.lines.count > 2)

        let boxHeight = full.lineHeight * 2
        let clipped = TextShaper.shape(style(long), maxWidth: worldWidth, maxHeight: boxHeight)
        #expect(clipped.lines.count == 2)

        let ink = render(layer(clipped, worldSize: CGSize(width: worldWidth, height: boxHeight), scale: 2))
        #expect(ink.rowBands.count == 2)          // exactly the fitting lines
        guard let box = ink.bounds else { Issue.record("no ink"); return }
        #expect(CGFloat(box.maxY) <= boxHeight * 2 + 1)   // nothing spills past the box
    }

    // MARK: - Degenerate inputs

    @Test("an empty layout draws nothing and does not crash")
    func emptyDrawsNothing() {
        let shaped = TextShaper.shape(style(""), maxWidth: nil)
        let l = layer(shaped, worldSize: CGSize(width: 40, height: shaped.size.height), scale: 2)
        #expect(render(l).isEmpty)      // a lone space has no ink
    }

    @Test("a zero-size or zero-scale layer draws nothing and does not crash")
    func degenerateGeometryIsSafe() {
        let shaped = TextShaper.shape(style(wrapping), maxWidth: worldWidth)
        let zeroBounds = TextRenderLayer()
        zeroBounds.setShaped(shaped)
        zeroBounds.bounds = .zero
        #expect(render(zeroBounds).isEmpty)

        let zeroScale = layer(shaped, worldSize: CGSize(width: worldWidth, height: 60), scale: 1)
        zeroScale.drawScale = 0
        #expect(render(zeroScale).isEmpty)
    }

    @Test("a world offset shifts the drawn window without moving the layout")
    func worldOffsetShiftsTheWindow() {
        // Centred in a wide box, so the ink sits well inside the layer and a
        // shift stays visible instead of clipping off the leading edge.
        let width: CGFloat = 300
        let shaped = TextShaper.shape(style("short", alignment: .center), maxWidth: width)
        let world = CGSize(width: width, height: shaped.size.height)
        let plain = render(layer(shaped, worldSize: world, scale: 2))
        let shifted = layer(shaped, worldSize: world, scale: 2)
        shifted.worldOffset = CGPoint(x: 10, y: 0)
        let shiftedInk = render(shifted)
        guard let a = plain.bounds, let b = shiftedInk.bounds else {
            Issue.record("missing ink"); return
        }
        // Ink moves left by offset × scale; the layout itself is untouched.
        #expect(abs((a.minX - b.minX) - 20) <= 2)
        #expect(abs((a.maxX - b.maxX) - 20) <= 2)
        #expect(plain.rowBands.count == shiftedInk.rowBands.count)
    }

    // MARK: - Redraw cadence (what the engine relies on in Step 3)

    @Test("re-applying the same layout and state schedules no redraw")
    func idempotentUpdatesDoNotInvalidate() {
        let shaped = TextShaper.shape(style(wrapping), maxWidth: worldWidth)
        let l = TextRenderLayer()
        let color = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        #expect(l.setShaped(shaped) == true)                 // first layout: redraw
        #expect(l.setShaped(shaped) == false)                // same key: nothing
        #expect(l.apply(scale: 2, color: color, worldOffset: .zero) == true)
        #expect(l.apply(scale: 2, color: color, worldOffset: .zero) == false)  // a pan
        #expect(l.apply(scale: 4, color: color, worldOffset: .zero) == true)   // a zoom
    }

    @Test("a differently-shaped layout does invalidate")
    func newLayoutInvalidates() {
        let l = TextRenderLayer()
        #expect(l.setShaped(TextShaper.shape(style(wrapping), maxWidth: 200)) == true)
        #expect(l.setShaped(TextShaper.shape(style(wrapping), maxWidth: 240)) == true)
        #expect(l.setShaped(TextShaper.shape(style("different"), maxWidth: 240)) == true)
    }

    @Test("colour is not part of the layout — a recolour keeps the same shaping")
    func colourIsNotLayout() {
        let a = TextShaper.shape(style(wrapping), maxWidth: worldWidth)
        var recoloured = style(wrapping)
        recoloured.color = RGBAColor(red: 1, green: 0, blue: 0)
        let b = TextShaper.shape(recoloured, maxWidth: worldWidth)
        #expect(a.key == b.key)          // same layout, no re-shape
        #expect(a.lines.count == b.lines.count)
    }
}
